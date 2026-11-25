import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';

import 'package:fushi/src/media/collections/add_to_collection_dialog.dart'
    show CollectionMemberVisibility, pickTargetCollectionForMembers;
import 'package:fushi/src/media/collections/collection_art_scrape.dart';
import 'package:fushi/src/media/collections/collection_ai_order.dart'
    show CollectionAiClientFactory;
import 'package:fushi/src/media/collections/collection_detail_hero.dart';
import 'package:fushi/src/media/collections/collection_drag.dart'
    show LibraryDragReorderScope, LibraryReorderCell;
import 'package:fushi/src/media/collections/collection_tag_row.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show
        ShellClip,
        ShellContentLayout,
        shellContentLayoutOf,
        shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show
        FushiCoverBlockScope,
        FushiCoverBlockSize,
        fushiCoverBlockRadius,
        fushiCoverImageOf;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show SliverFushiCoverBlocks, kFushiCoverBlockTargetWidthSingle;
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi/src/media/collections/collection_member_view.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/library_reorder.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus;
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show
        collectionDetailSortPrefKey,
        kCollectionDetailManualSortValue,
        loadCollectionMemberMeta,
        sortedCollectionRows;
import 'package:fushi/src/media/collections/collection_shelf_row.dart'
    show unifiedShelfCardLayout;
import 'package:fushi/src/pages/implementations/collection_detail_shared.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart'
    show DialogListAction, MediaItemDialogFrame, showMediaItemActions;
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame, ShelfGridCellInset, shelfBookCellAspectRatio;
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import 'package:fushi/src/utils/components/fushi_divider.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/pages/implementations/library_view_options.dart'
    show libraryGridSizeClassOf;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 合集详情页（书架 / 漫画库 / 游戏库共用；2026-10-06 M3E 重设计）。
///
/// - **hero**（[CollectionDetailHeroCard]）：堆叠封面 + 合集名 + 项数 / 读完数 +
///   整体进度波浪条 + 「继续」主按钮 + 彩色标签 chip；宽屏左右排、窄屏上下排。
/// - **成员工具条**：合集内搜索、筛选（标签 / 阅读状态）、排序（卷号 / 添加时间 /
///   阅读时间 / 手动）、网格 ↔ 列表、多选。卷号 / 添加时间 / 阅读时间是**视图排序**
///   （不落库），「存为手动顺序」才写穿 sortIndex（即旧的一键整理）。
/// - **成员**：无筛选的网格是可拖排网格（[FushiReorderableGrid]，消缩放 2D 拖排，
///   落盘 sortIndex 与库页合集行同源，筛选态下保序合并 [mergeCollectionOrder]）；
///   其余是错峰进场的普通网格 / 列表。长按与库页卡片同一时机直接弹成员菜单；
///   触屏重排从菜单「排序」进入排序模式（[LibraryReorderHost]，筛选 / 列表下
///   也进拖排网格），底部 [LibraryReorderBar]「完成」退出。
/// - **多选批量**：移出合集、打标签（共享 [showTagPicker]）、标记读完 / 未读、移到
///   其他合集；底部 M3E 浮动操作栏（spring 进出）。
///
/// 成员卡由调用方 [memberCardBuilder] 按 mediaType/entryKey 提供；进度 / 封面 /
/// 读完状态由可选的 [memberInfoOf] 提供（不传时进度、阅读状态筛选、标记读完不出现）。
/// 删除合集只解链、绝不删条目（除非勾选连同成员一起删）；移空后合集自删并退回上层。
class MediaCollectionGridDetailPage extends StatefulWidget {
  const MediaCollectionGridDetailPage({
    required this.database,
    required this.collection,
    required this.memberCardBuilder,
    required this.onChanged,
    this.onOpenMember,
    this.onShowMemberMenu,
    this.onDeleteMembersMedia,
    this.deleteMembersStatisticsSubtitle,
    this.memberInfoOf,
    this.memberHasRichMetadata,
    this.collectionSeriesFallback,
    this.memberInfoRefresh,
    this.onSetMembersCompleted,
    this.isMemberVisible,
    this.collectionAiSettings,
    this.memberCoverOf,
    this.memberNsfwOf,
    this.aiClientFactory,
    this.artScrape,
    this.trackingSection,
    super.key,
  });

  /// The card's "Tracking" section under its members (series links of book
  /// and manga cards: one link counts every volume). Null = none (tracking
  /// off, games).
  final Widget? trackingSection;

  /// 书 / 漫画合集的「获取各卷封面与横幅」「清除已获取的封面」。null = 不提供
  /// （游戏库等）；合集里没有本地书或「在线服务」模块关着时也不出现。
  final CollectionArtScrape? artScrape;

  final FushiDatabase database;
  final MediaCollectionRow collection;

  /// 「排序」菜单的「AI 排序」用的 AI 指派来源。null = 不显示该项（AI 模块关着，
  /// 调用方按 `isAiModuleEnabled` 求值后传）。
  final AiSettingsSource? collectionAiSettings;

  /// 测试注入假 AI 客户端；生产为 null（默认构造）。
  final CollectionAiClientFactory? aiClientFactory;

  /// 按成员 (mediaType, entryKey) 渲染卡片；返回 null = 该成员当前不可见（孤儿/被过滤），
  /// 详情页跳过它。
  ///
  /// [onRemoveFromCollection]（详情页在此处注入 `() => _removeMember(row)`）供调用方把
  /// 「移出合集」接进该成员卡的**长按/右键对话框**（[MediaItemDialogPage] 的 extraActions）。
  /// 触摸/鼠标经网格接管走上下文菜单移出，但键盘/手柄用户是聚焦长按 A 弹卡片自身的
  /// [MediaItemDialogPage]（不经网格指针路径），若不注入就没有移出项——故给可聚焦对话框
  /// 补一条「移出合集」DialogAction，键盘/手柄用户不失能。
  final Widget? Function(
    String mediaType,
    String entryKey, {
    VoidCallback? onRemoveFromCollection,
  })
  memberCardBuilder;

  /// 打开某成员（点卡片 / 菜单「打开」/ hero「继续」）。null = 不提供打开。卡片自身的
  /// 手势被 [IgnorePointer] 屏蔽（避免其内部 long-press 与网格触摸拖拽争用），故「打开」
  /// 统一经此回调，由调用方按 (mediaType, entryKey) 找到条目并打开。
  final void Function(String mediaType, String entryKey)? onOpenMember;

  /// 与 [memberCardBuilder] 同一判据、但不建卡的可见性谓词：「移到其他合集」
  /// 弹窗按它数各合集的成员（BUG-3361）。null = 按原始成员行数。
  final CollectionMemberVisibility? isMemberVisible;

  /// 成员卡的上下文菜单（网格右键 / 触摸长按）。非 null 时整个菜单交给调用方：
  /// 书架传入与库页书卡**同一个**菜单构建（标签 / 标记读完 / 删除 / 重命名…再补
  /// 「移出合集」，[onRemoveFromCollection] 即本页的移出流程），合集内外右键一致
  /// （BUG-2969：此前合集内只有「打开 / 移出」两项，选不了标签、也读不出这是同一本书）。
  /// null = 本页自带的「打开 / 移出」精简菜单（游戏库等没有卡片级菜单的调用方）。
  final Future<void> Function(
    String mediaType,
    String entryKey, {
    required VoidCallback onRemoveFromCollection,
  })?
  onShowMemberMenu;

  /// 改名 / 删除 / 移出成员后刷新书架。
  final VoidCallback onChanged;

  /// 「删除合集」时可选连同成员本体一起删（默认不删，保持只解链语义）。null = 详情页
  /// 不提供该选项（确认框不显示复选框），退回纯解链删除。
  final Future<void> Function(
    List<MediaCollectionItemRow> members,
    bool deleteLocalFiles,
    bool deleteStatistics,
  )?
  onDeleteMembersMedia;

  /// 「同时删除统计数据」勾选行的副标题；null = 不提供该选项。
  final String? deleteMembersStatisticsSubtitle;

  /// 成员的展示信息（显示名 / 纯封面 / 进度 / 最后阅读时刻 / 读完）。null = 调用方
  /// 不提供：hero 不画进度、没有阅读状态筛选与「阅读时间」排序、没有标记读完。
  final CollectionMemberInfoResolver? memberInfoOf;

  /// 成员是否刮削过（有单本刮削资料或横版海报）；null = 认不出的成员。给了它时
  /// **窄屏**色块成员墙分两段：刮削过的在上段画色块，其余在下段画普通封面网格
  /// （与书架库墙同一规则，2026-11-16 用户拍板方案 A）。不给 = 不分段。
  final bool? Function(String mediaType, String entryKey)?
  memberHasRichMetadata;

  /// 合集自己没有刮削资料 / 背景图时，头部系列横幅借用的成员资料（书架：最前
  /// 那卷的单本刮削资料与横版海报）；null = 不借，头部保持原样。
  final ({FushiSeriesMeta meta, String? summary})? Function()?
  collectionSeriesFallback;

  /// 头部封面扇形 / 取色用的成员纯封面，[memberInfoOf] 没给封面时的后备。给游戏
  /// 这类没有阅读进度（不传 [memberInfoOf]，否则会冒出读完筛选 / 标记读完）但有
  /// 封面的成员用；null = 只认 [memberInfoOf] 的封面。
  final Widget? Function(String mediaType, String entryKey)? memberCoverOf;

  /// 头部成员封面（扇形 / 大封面）逐张判定 NSFW 用的宿主（拍板台 w04vrhUAaX）。
  /// null = 按成员行 [MediaNsfwTarget.collectionMember]；游戏要并入自己的成人向
  /// 标记，由调用方给。成员卡自己的封面由 [memberCardBuilder] 的卡壳负责。
  final MediaNsfwTarget? Function(String mediaType, String entryKey)?
  memberNsfwOf;

  /// [memberInfoOf] 背后的数据（最后阅读时刻 / 进度 / 读完）变了的通知。详情页是压在
  /// 阅读器之下的独立路由，不会因调用方的 provider 变化而重建；不订阅这条，读完一本
  /// 回到详情页，「继续阅读」与 hero 进度仍停在进页时的快照（4h4uGUck4k）。
  final Listenable? memberInfoRefresh;

  /// 多选「标记读完 / 未读」落库（调用方按成员种类写各自的读完真值）。null = 不提供。
  final Future<void> Function(
    List<MediaCollectionItemRow> members,
    bool completed,
  )?
  onSetMembersCompleted;

  @override
  State<MediaCollectionGridDetailPage> createState() =>
      _MediaCollectionGridDetailPageState();
}

class _MediaCollectionGridDetailPageState
    extends State<MediaCollectionGridDetailPage>
    with
        CollectionDetailShared<MediaCollectionGridDetailPage>,
        LibraryReorderHost<MediaCollectionGridDetailPage> {
  late String _name;
  List<MediaCollectionItemRow> _rows = const <MediaCollectionItemRow>[];

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

  bool _loading = true;

  /// 成员标题 / 导入时刻（四表现查，与一键整理同一份）。
  Map<String, ({String title, int importedAt})> _meta =
      const <String, ({String title, int importedAt})>{};

  /// 成员身份键 → 所挂标签 id（标签筛选用）。
  Map<String, Set<int>> _memberTagIds = const <String, Set<int>>{};

  /// 合集的刮削资料（[CollectionScrapeMeta] 行）与附加图组里 position 最小且
  /// 文件还在的横版背景图 / 艺术字路径（[_reload] 里一并取好、存在性探好，build
  /// 零 IO）。有其一时合集信息块换成系列海报 hero（[_buildSeriesHero]）。
  CollectionScrapeMetaRow? _scrapeMeta;
  String? _backdropPath;
  String? _logoPath;

  /// 「获取各卷封面与横幅」下到的系列横幅（[BookArtStore.backdropForCollection]，
  /// 成员多数票那张；只有书 / 漫画合集、且确实下到过才非 null）。合集自己没有
  /// 背景图时它顶上 hero 背景带。[_reload] 与刮削层变更时重算，build 零 IO。
  String? _artBannerPath;

  /// 正在监听的刮削层变更（[CollectionArtScrape.changes]）；没传 [artScrape] 为 null。
  Listenable? _artChanges;

  /// 全部标签（筛选面板取名 / 色）与合集自身的标签（hero）。
  List<BookTagRow> _allTags = const <BookTagRow>[];
  List<BookTagRow> _collectionTags = const <BookTagRow>[];

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 默认按卷号：成员表 sortIndex 只是加入顺序（逐本加入、目录扫描序），不是
  /// 用户排出来的序——直接按它展示就是「21, 25, 24, 23, 22」。每合集偏好
  /// （[collectionDetailSortPrefKey]）记着用户选过的排序；用户保存过手动顺序
  /// （选「手动」/ 拖拽 / 存为手动顺序 / 一键整理）后才默认走手动序。
  CollectionMemberSort _sort = CollectionMemberSort.volume;

  /// 排序偏好只在首次加载时读一次；之后成员增删的 reload 不覆盖本页当前选择。
  bool _sortPrefLoaded = false;
  CollectionMemberViewMode _viewMode = CollectionMemberViewMode.grid;
  Set<int> _tagFilter = <int>{};
  ShelfReadStatus? _statusFilter;
  bool _filtersOpen = false;
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  /// 排序模式（成员菜单「排序」进入）：触屏按住即拖，见 [LibraryReorderHost]。
  bool _reordering = false;

  /// hero 滚出视口后 AppBar 才显示合集名。
  bool _titleVisible = false;

  @override
  void initState() {
    super.initState();
    _name = widget.collection.name;
    _scroll.addListener(_onScroll);
    widget.memberInfoRefresh?.addListener(_onMemberInfoChanged);
    _artChanges = widget.artScrape?.changes;
    _artChanges?.addListener(_onArtStoreChanged);
    _reload();
  }

  /// 刮削层写入 / 清除（本页按钮、ops 路由、单本编辑弹窗都走它）后重算横幅。
  void _onArtStoreChanged() => unawaited(_refreshArtBanner());

  /// 按当前成员重算横幅；算完时成员已被 [_reload] 换掉就丢弃（那次 reload 自带横幅）。
  Future<void> _refreshArtBanner() async {
    if (!mounted) return;
    final List<MediaCollectionItemRow> rows = _rows;
    final String? next = await _artBannerFor(rows);
    if (!mounted || !identical(rows, _rows)) return;
    if (next != _artBannerPath) setState(() => _artBannerPath = next);
  }

  /// [rows] 里书成员的合集横幅路径；没有刮削层 / 没下到为 null。
  Future<String?> _artBannerFor(List<MediaCollectionItemRow> rows) async =>
      (await widget.artScrape?.bannerFor(rows))?.path;

  void _onMemberInfoChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MediaCollectionGridDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.memberInfoRefresh != widget.memberInfoRefresh) {
      oldWidget.memberInfoRefresh?.removeListener(_onMemberInfoChanged);
      widget.memberInfoRefresh?.addListener(_onMemberInfoChanged);
    }
    final Listenable? changes = widget.artScrape?.changes;
    if (!identical(changes, _artChanges)) {
      _artChanges?.removeListener(_onArtStoreChanged);
      _artChanges = changes;
      _artChanges?.addListener(_onArtStoreChanged);
      unawaited(_refreshArtBanner());
    }
  }

  @override
  void dispose() {
    widget.memberInfoRefresh?.removeListener(_onMemberInfoChanged);
    _artChanges?.removeListener(_onArtStoreChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    final bool visible = _scroll.hasClients && _scroll.offset > 220;
    if (visible != _titleVisible) setState(() => _titleVisible = visible);
  }

  Future<void> _reload() async {
    final FushiDatabase db = widget.database;
    final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
      widget.collection.id,
    );
    final Map<String, ({String title, int importedAt})> meta =
        await loadCollectionMemberMeta(db);
    final Map<String, Set<int>> tagIds = <String, Set<int>>{};
    for (final MediaCollectionItemRow row in rows) {
      final MediaRef? ref = await tagRefForCollectionMember(db, row);
      if (ref == null) continue;
      tagIds['${row.mediaType}|${row.entryKey}'] = <int>{
        for (final BookTagRow tag in await tagsForMediaRef(db, ref)) tag.id,
      };
    }
    final List<BookTagRow> allTags = await db.getAllTags();
    final List<BookTagRow> collectionTags = await db.getTagsForCollection(
      widget.collection.id,
    );
    final CollectionScrapeMetaRow? scrapeMeta = await db
        .getCollectionScrapeMeta(widget.collection.id);
    final List<MediaImageRow> images = await db.getMediaImagesForCollection(
      widget.collection.id,
    );
    final String? backdropPath = await _firstExistingImage(
      images,
      MediaImageKind.backdrop,
    );
    final String? logoPath = await _firstExistingImage(
      images,
      MediaImageKind.logo,
    );
    final String? artBannerPath = await _artBannerFor(rows);
    CollectionMemberSort? savedSort;
    if (!_sortPrefLoaded) {
      final String? raw = await db.getPref(
        collectionDetailSortPrefKey(widget.collection.id),
      );
      for (final CollectionMemberSort s in CollectionMemberSort.values) {
        if (s.name == raw) savedSort = s;
      }
      // 阅读时间排序要靠调用方给的最后阅读时刻；没有就回落默认卷号。
      if (savedSort == CollectionMemberSort.read &&
          widget.memberInfoOf == null) {
        savedSort = null;
      }
    }
    if (!mounted) return;
    final CollectionMemberSort? restoredSort = savedSort;
    setState(() {
      if (!_sortPrefLoaded) {
        _sortPrefLoaded = true;
        if (restoredSort != null) _sort = restoredSort;
      }
      _rows = rows;
      _meta = meta;
      _memberTagIds = tagIds;
      _allTags = allTags;
      _collectionTags = collectionTags;
      _scrapeMeta = scrapeMeta;
      _backdropPath = backdropPath;
      _logoPath = logoPath;
      _artBannerPath = artBannerPath;
      _loading = false;
      _selected.retainWhere(
        (String key) => rows.any(
          (MediaCollectionItemRow r) => '${r.mediaType}|${r.entryKey}' == key,
        ),
      );
    });
  }

  /// [images] 里 [kind] 种类、position 最小且文件还在的那张的路径；没有为 null。
  static Future<String?> _firstExistingImage(
    List<MediaImageRow> images,
    MediaImageKind kind,
  ) async {
    final List<MediaImageRow> rows =
        images
            .where(
              (MediaImageRow r) => r.kind == kind.dbValue && r.path.isNotEmpty,
            )
            .toList()
          ..sort(
            (MediaImageRow a, MediaImageRow b) =>
                a.position.compareTo(b.position),
          );
    for (final MediaImageRow row in rows) {
      if (await File(row.path).exists()) return row.path;
    }
    return null;
  }

  /// 切换排序方式并记进本合集的排序偏好（下次打开沿用）。
  void _setSort(CollectionMemberSort sort) {
    setState(() => _sort = sort);
    _persistSort(sort);
  }

  Future<void> _persistSort(CollectionMemberSort sort) =>
      widget.database.setPref(
        collectionDetailSortPrefKey(widget.collection.id),
        sort == CollectionMemberSort.manual
            ? kCollectionDetailManualSortValue
            : sort.name,
      );

  /// 阅读时间排序没有一键整理比较器：按页内视图序排，视图外的成员保持原序接在后面。
  List<MediaCollectionItemRow> _rowsInViewOrder(
    List<CollectionMemberEntry> arranged,
  ) {
    final Set<String> shown = <String>{
      for (final CollectionMemberEntry e in arranged) e.key,
    };
    return <MediaCollectionItemRow>[
      for (final CollectionMemberEntry e in arranged) e.row,
      for (final MediaCollectionItemRow r in _rows)
        if (!shown.contains('${r.mediaType}|${r.entryKey}')) r,
    ];
  }

  /// 「存为手动顺序」（原一键整理，排序交互重设计层次 B2）：把当前视图排序写穿
  /// sortIndex（`reorderCollectionItems`），库页合集行同源立即同序。阅读时间排序
  /// 没有对应的一键整理比较器，按页内视图序落盘。
  Future<void> _saveViewOrder(List<CollectionMemberEntry> arranged) async {
    // 用 switch 表达式在声明处取值，不在 switch 语句里给推迟赋值的 final 赋值再让
    // setState 闭包捕获（Dart 3.14.0 AOT 对该形状有 dart-lang/sdk#64917 崩溃，
    // 修复 dart-lang/sdk@7848cfe821d；守卫
    // test/build/aot_deferred_final_switch_capture_guard_test.dart）。
    final List<MediaCollectionItemRow>? sorted = switch (_sort) {
      CollectionMemberSort.manual => null,
      CollectionMemberSort.volume ||
      CollectionMemberSort.added => await sortedCollectionRows(
        db: widget.database,
        rows: _rows,
        byTitle: _sort == CollectionMemberSort.volume,
      ),
      CollectionMemberSort.read => _rowsInViewOrder(arranged),
    };
    if (sorted == null) return;
    final List<MediaCollectionItemRow> next = sorted;
    if (!mounted) return;
    setState(() {
      _rows = next;
      _sort = CollectionMemberSort.manual;
    });
    await _persistSort(CollectionMemberSort.manual);
    await widget.database
        .reorderCollectionItems(widget.collection.id, <CollectionMemberKey>[
          for (final MediaCollectionItemRow r in next)
            (mediaType: r.mediaType, entryKey: r.entryKey),
        ]);
    widget.onChanged();
  }

  /// 「AI 排序」：卷号判不出的卷（汉字卷号 / 上下卷 / 外传）交 AI 定位后整表落盘；
  /// 落了盘即切到手动序展示（偏好已由 [runDetailAiSort] 写成 manual）。
  Future<void> _sortWithAi(AiSettingsSource settings) async {
    final bool persisted = await runDetailAiSort(
      settings: settings,
      clientFactory: widget.aiClientFactory,
    );
    if (!persisted || !mounted) return;
    setState(() => _sort = CollectionMemberSort.manual);
    await _reload();
  }

  Future<void> _delete() async {
    // 仅当调用方注入了删本体回调、且合集当前有成员时，才给用户「连同书一起删」
    // 勾选行；否则退回纯解链删除。确认框统一走 [confirmDetailCollectionDelete]。
    final bool canDeleteMembers =
        widget.onDeleteMembersMedia != null && _rows.isNotEmpty;
    final FushiDestructiveConfirmResult?
    result = await confirmDetailCollectionDelete(
      checkboxLabel: canDeleteMembers ? t.delete_collection_also_books : null,
      statisticsSubtitle: canDeleteMembers
          ? widget.deleteMembersStatisticsSubtitle
          : null,
      checkedDisclosure: canDeleteMembers
          ? buildDeletionDisclosure(target: DeletionDisclosureTarget.shelfBook)
          : null,
    );
    if (result == null || !mounted) return;
    // 先删成员本体，再解散容器（清残留引用 + 合集级墓碑 + 回收合集自有封面，BUG-1319）。
    if (result.checked && widget.onDeleteMembersMedia != null) {
      await widget.onDeleteMembersMedia!(
        List<MediaCollectionItemRow>.of(_rows),
        false,
        result.deleteStatistics,
      );
    }
    await deleteMediaCollectionWithAssets(
      widget.database,
      widget.collection.id,
    );
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  Future<void> _removeMember(MediaCollectionItemRow row) async {
    // 按成员行值移出（行值可能是对端未知种类）→ raw 版，保证移得掉。
    await widget.database.removeFromCollectionRaw(
      widget.collection.id,
      row.mediaType,
      row.entryKey,
    );
    if (!mounted) return;
    widget.onChanged();
    await _afterMembershipChange();
  }

  /// 移出 / 移走成员后：移空则合集已自删（removeFromCollection），退回上层；否则重载。
  Future<void> _afterMembershipChange() async {
    final List<MediaCollectionItemRow> remaining = await widget.database
        .getCollectionItems(widget.collection.id);
    if (!mounted) return;
    if (remaining.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    await _reload();
  }

  /// 网格拖拽落序：from/to 是**显示序** [arranged] 的下标（卷号 / 加入时间 /
  /// 阅读时间排序下与 [_rows] 的手动序不同）。先在显示序上应用 removeAt/insert，
  /// 再用共享的 [mergeCollectionOrder] **保序合并**回 [_rows] 全表：可见槽按新
  /// 显示序依次填入、孤儿行（当前不可见）留在原下标；随后切到手动序展示。
  Future<void> _onReorder(
    List<CollectionMemberEntry> arranged,
    int from,
    int to,
  ) async {
    if (from == to) return;
    final List<MediaCollectionItemRow> visible = <MediaCollectionItemRow>[
      for (final CollectionMemberEntry e in arranged) e.row,
    ];
    if (from < 0 || from >= visible.length || to < 0 || to >= visible.length) {
      return;
    }
    final MediaCollectionItemRow moved = visible.removeAt(from);
    visible.insert(to, moved);
    final List<MediaCollectionItemRow> next = mergeCollectionOrder(
      all: _rows,
      subset: visible,
      keyOf: (MediaCollectionItemRow r) =>
          (mediaType: r.mediaType, entryKey: r.entryKey),
    );
    setState(() {
      _rows = next;
      _sort = CollectionMemberSort.manual;
    });
    await _persistSort(CollectionMemberSort.manual);
    await widget.database
        .reorderCollectionItems(widget.collection.id, <CollectionMemberKey>[
          for (final MediaCollectionItemRow r in visible)
            (mediaType: r.mediaType, entryKey: r.entryKey),
        ]);
    widget.onChanged();
  }

  /// 长按 / 右键 / 「⋯」上下文菜单（菜单里的「排序」进入本页排序模式）。
  ///
  /// 容器由 [showMediaItemActions] 按触发方式决定，与库页卡片同一套：右键（同步
  /// 派发期间 [activeContextMenuAnchor] 非空）在指针处弹右键菜单，长按 / ⋯ /
  /// 键盘手柄弹抽屉或对话框。调用方的共享菜单（[MediaCollectionGridDetailPage.onShowMemberMenu]）
  /// 必须在第一个 await 之前弹出，才读得到锚点。
  Future<void> _showMemberMenu(
    MediaCollectionItemRow row,
    Offset globalPosition,
  ) async {
    final Future<void> Function(
      String mediaType,
      String entryKey, {
      required VoidCallback onRemoveFromCollection,
    })?
    shared = widget.onShowMemberMenu;
    if (shared != null) {
      // BUG-2969：调用方的卡片菜单（与库页同一份），移出合集仍走本页流程。
      // 菜单在调用方 context 上弹出，「排序」入口须同步压成本页的（否则指向库页）。
      Future<void> pending = Future<void>.value();
      runWithLibraryReorder(_startReorder, () {
        pending = shared(
          row.mediaType,
          row.entryKey,
          onRemoveFromCollection: () => _removeMember(row),
        );
      });
      await pending;
      if (mounted) await _reload();
      return;
    }
    final void Function(String mediaType, String entryKey)? open =
        widget.onOpenMember;
    final _MemberMenuAction?
    action = await showMediaItemActions<_MemberMenuAction>(
      context: context,
      builder: (BuildContext menuContext) => MediaItemDialogFrame(
        title: _meta['${row.mediaType}|${row.entryKey}']?.title ?? row.entryKey,
        showLaunchAction: open != null,
        launchLabel: t.collection_open,
        onLaunch: () => Navigator.pop(menuContext, _MemberMenuAction.open),
        listActions: <DialogListAction>[
          DialogListAction(
            label: t.collection_remove_member,
            icon: FushiIcons.removeCircle,
            onPressed: () =>
                Navigator.pop(menuContext, _MemberMenuAction.remove),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MemberMenuAction.open:
        open?.call(row.mediaType, row.entryKey);
      case _MemberMenuAction.remove:
        await _removeMember(row);
    }
  }

  /// 编辑合集自身的标签（共享标签选择器，合集路）；返回后重载 hero 标签。
  Future<void> _editCollectionTags() async {
    await showTagPicker(
      context,
      targets: TagTargets(collectionIds: <int>[widget.collection.id]),
    );
    if (!mounted) return;
    widget.onChanged();
    await _reload();
  }

  // ── 多选 ──────────────────────────────────────────────────────────────

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selected.clear();
      _reordering = false;
    });
  }

  // ── 排序模式 ──────────────────────────────────────────────────────────

  void _startReorder() {
    if (!mounted) return;
    setState(() {
      _reordering = true;
      _selecting = false;
      _selected.clear();
    });
  }

  void _endReorder() => setState(() => _reordering = false);

  @override
  VoidCallback? get libraryReorderEntry => _startReorder;

  void _toggleSelected(CollectionMemberEntry entry) {
    setState(() {
      if (!_selected.remove(entry.key)) _selected.add(entry.key);
      if (!_selecting) _selecting = true;
    });
  }

  List<MediaCollectionItemRow> get _selectedRows => <MediaCollectionItemRow>[
    for (final MediaCollectionItemRow r in _rows)
      if (_selected.contains('${r.mediaType}|${r.entryKey}')) r,
  ];

  void _endSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  Future<void> _batchRemove() async {
    final List<MediaCollectionItemRow> rows = _selectedRows;
    if (rows.isEmpty || !await confirmDetailRemoveMember() || !mounted) return;
    for (final MediaCollectionItemRow row in rows) {
      await widget.database.removeFromCollectionRaw(
        widget.collection.id,
        row.mediaType,
        row.entryKey,
      );
    }
    if (!mounted) return;
    widget.onChanged();
    _endSelection();
    FushiToast.show(
      msg: t.collection_member_removed,
      severity: ToastSeverity.success,
    );
    await _afterMembershipChange();
  }

  Future<void> _batchTag() async {
    final List<MediaRef> refs = <MediaRef>[];
    for (final MediaCollectionItemRow row in _selectedRows) {
      final MediaRef? ref = await tagRefForCollectionMember(
        widget.database,
        row,
      );
      if (ref != null) refs.add(ref);
    }
    if (refs.isEmpty || !mounted) return;
    final bool changed = await showTagPicker(
      context,
      targets: TagTargets(media: refs),
    );
    if (!mounted) return;
    if (changed) widget.onChanged();
    await _reload();
  }

  Future<void> _batchSetCompleted(bool completed) async {
    final Future<void> Function(List<MediaCollectionItemRow>, bool)? apply =
        widget.onSetMembersCompleted;
    final List<MediaCollectionItemRow> rows = _selectedRows;
    if (apply == null || rows.isEmpty) return;
    await apply(rows, completed);
    if (!mounted) return;
    widget.onChanged();
    _endSelection();
    FushiToast.show(
      msg: completed ? t.book_marked_completed : t.book_marked_uncompleted,
      severity: ToastSeverity.success,
    );
  }

  Future<void> _batchMove() async {
    final List<MediaCollectionItemRow> rows = _selectedRows;
    if (rows.isEmpty) return;
    final MediaKind? domainKind = MediaKind.tryParse(rows.first.mediaType);
    if (domainKind == null) return;
    final int? target = await pickTargetCollectionForMembers(
      context: context,
      database: widget.database,
      domainKind: domainKind,
      domainEntryKey: rows.first.entryKey,
      currentCollectionId: widget.collection.id,
      isMemberVisible: widget.isMemberVisible,
    );
    if (target == null || target == widget.collection.id || !mounted) return;
    // 先加进目标再移出本合集：移空自删发生在最后一步，目标里成员已就位。
    for (final MediaCollectionItemRow row in rows) {
      await widget.database.addToCollectionRaw(
        target,
        row.mediaType,
        row.entryKey,
      );
    }
    for (final MediaCollectionItemRow row in rows) {
      await widget.database.removeFromCollectionRaw(
        widget.collection.id,
        row.mediaType,
        row.entryKey,
      );
    }
    if (!mounted) return;
    widget.onChanged();
    _endSelection();
    FushiToast.show(
      msg: t.collection_detail_moved(n: rows.length),
      severity: ToastSeverity.success,
    );
    await _afterMembershipChange();
  }

  // ── 构建 ──────────────────────────────────────────────────────────────

  /// AppBar 动作收纳的回差状态（见 [FushiHeaderOverflowFit]）。
  final FushiHeaderOverflowFit _appBarActionsFit = FushiHeaderOverflowFit();

  /// [availableWidth] 是这条 AppBar 实际拿到的约束宽（由 [LayoutBuilder] 下发）。
  PreferredSizeWidget _buildAppBar(
    double availableWidth,
    List<CollectionMemberEntry> arranged,
  ) {
    return FushiAppBar(
      // hero 里已经有大号合集名；滚过 hero 后才在 AppBar 淡入。
      title: AnimatedOpacity(
        opacity: _titleVisible ? 1 : 0,
        duration: fushiMotionDuration(context, FushiMotion.short),
        child: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      // BUG-1184：放不下时按优先级逐颗把动作收进 ⋯，给合集名让出宽度；判据与
      // 页头同一套（[fushiResolveHeaderActions]），宽度取这条 AppBar 的局部约束。
      actions: fushiResolveHeaderActions(
        context,
        actions: <Widget>[
          FushiIconButton(
            icon: FushiIcons.rename,
            tooltip: t.rename_collection,
            onTap: renameDetailCollection,
          ),
          // 「编辑标签」只在 hero（标签 chip 旁）一处：顶栏再摆一颗同功能的标签钮
          // 是重复入口（用户实报两个按钮功能重复）。
          if (_sort != CollectionMemberSort.manual)
            FushiIconButton(
              icon: FushiIcons.download,
              tooltip: t.collection_detail_save_order,
              onTap: () => _saveViewOrder(arranged),
            ),
          if (_artScrapeAvailable) ...<Widget>[
            FushiIconButton(
              icon: FushiIcons.imageSearch,
              tooltip: t.collection_art_scrape_action,
              onTap: _scrapeArt,
            ),
            FushiIconButton(
              icon: FushiIcons.deleteSweep,
              tooltip: t.collection_art_scrape_clear,
              onTap: _clearArt,
            ),
          ],
          FushiIconButton(
            icon: FushiIcons.delete,
            tooltip: t.delete_collection,
            onTap: _delete,
          ),
        ],
        budget: fushiAppBarActionsBudget(context, availableWidth),
        fit: _appBarActionsFit,
      ).items,
    );
  }

  /// 色块语言是否生效：库页布局不是封面网格。
  bool _blockStyleFor(List<CollectionMemberEntry> entries) =>
      shellContentLayoutOf(context) != ShellContentLayout.grid;

  /// 窄屏（compact 档）色块成员墙按元数据分两段（与书架库墙同一规则，2026-11-16
  /// 用户拍板方案 A）：刮削过的成员在上段画色块，其余在下段画普通封面网格。
  /// 没给 [MediaCollectionGridDetailPage.memberHasRichMetadata] 时不分段。
  bool get _splitsByMetadata =>
      widget.memberHasRichMetadata != null &&
      libraryGridSizeClassOf(context) == WindowSizeClass.compact;

  bool _memberIsRich(CollectionMemberEntry e) =>
      widget.memberHasRichMetadata?.call(e.row.mediaType, e.row.entryKey) ??
      false;

  @override
  Widget build(BuildContext context) {
    final Map<String, Widget> cards = <String, Widget>{};
    final List<CollectionMemberEntry> entries = <CollectionMemberEntry>[];
    // 上锁（未解锁）的成员不画（[MediaVisibility]，唯一的上锁过滤入口）。
    final MediaVisibility lockVisibility = MediaVisibility.of(context);
    for (final MediaCollectionItemRow r in _rows) {
      if (lockVisibility.hidesCollectionMember(r.mediaType, r.entryKey)) {
        continue;
      }
      final Widget? card = widget.memberCardBuilder(
        r.mediaType,
        r.entryKey,
        onRemoveFromCollection: () => _removeMember(r),
      );
      if (card == null) continue;
      final String key = '${r.mediaType}|${r.entryKey}';
      final ({String title, int importedAt})? meta = _meta[key];
      // 详情页成员卡与库页同一套条目材质（2026-10-25 库页定版）。
      final ShelfCoverMaterial? material = _coverMaterialFor(r.mediaType);
      cards[key] = material == null
          ? card
          : ShelfCoverMaterialScope(material: material, child: card);
      entries.add(
        CollectionMemberEntry(
          row: r,
          title: meta?.title ?? r.entryKey,
          importedAt: meta?.importedAt ?? 0,
          info: widget.memberInfoOf?.call(r.mediaType, r.entryKey),
          tagIds: _memberTagIds[key] ?? const <int>{},
        ),
      );
    }
    final List<CollectionMemberEntry> arranged = arrangeCollectionMembers(
      entries,
      sort: _sort,
      query: _search.text,
      tagIds: _tagFilter,
      status: _statusFilter,
    );
    final bool filtered =
        _search.text.trim().isNotEmpty ||
        _tagFilter.isNotEmpty ||
        _statusFilter != null;

    final bool redesign = shellRedesignActive(context);
    Widget withPopScope(Widget child) => PopScope(
      canPop: !_selecting && !_reordering,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (_reordering) {
          _endReorder();
        } else if (_selecting) {
          _endSelection();
        }
      },
      child: child,
    );
    List<Widget> overlays() => <Widget>[
      _buildSelectionBar(arranged),
      LibraryReorderBar.overlay(
        context: context,
        visible: _reordering,
        onDone: _endReorder,
      ),
    ];
    final Widget? placeholder = _loading
        ? Center(child: adaptiveIndicator(context: context))
        : entries.isEmpty
        ? _EmptyCollection(onBack: () => Navigator.of(context).maybePop())
        : null;

    if (redesign) {
      // 重设计外壳：与视频 / 漫画系列详情同一套海报面板（封面取色整页底 + 斜放
      // 海报 + 大标题 + 信息胶囊 + 继续 + 动作栏），不挂 AppBar：返回键与合集
      // 管理动作（重命名 / 存为手动顺序 / 删除）是 [MediaPosterDetailChrome] 的
      // 裸图标页头（桌面画进窗口标题行）。正文铺到窗口底，多选 / 排序浮动栏
      // 单独让开底部安全区。墨水屏走下面的原版式。
      // 色块风格（库页布局为拼贴 / 规整色块）：页面保持 app 底色，与库页色块墙
      // 同一观感——封面色只在左栏合集块与各成员色块上；封面网格布局整页取色。
      final bool blockStyle = _blockStyleFor(entries);
      final Widget chrome = MediaPosterDetailChrome(
        actions: _headerActions(arranged),
        child: placeholder != null
            ? Builder(
                builder: (BuildContext context) => ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(child: placeholder),
                ),
              )
            : withPopScope(
                Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: _buildScroll(entries, arranged, cards, filtered),
                    ),
                    Positioned.fill(
                      child: SafeArea(
                        top: false,
                        child: Stack(children: overlays()),
                      ),
                    ),
                  ],
                ),
              ),
      );
      return Scaffold(
        body: blockStyle
            ? chrome
            : MediaPosterDetailTheme(
                image: _heroCoverImage(entries),
                fallbackKey: _name,
                child: chrome,
              ),
      );
    }

    return Scaffold(
      // BUG-1186：折叠判据取这条 AppBar 的局部约束宽，不是整窗宽。
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              _buildAppBar(constraints.maxWidth, arranged),
        ),
      ),
      body: SafeArea(
        child:
            placeholder ??
            withPopScope(
              Stack(
                children: <Widget>[
                  _buildScroll(entries, arranged, cards, filtered),
                  ...overlays(),
                ],
              ),
            ),
      ),
    );
  }

  /// 重设计外壳页头右侧的合集管理动作（与原 AppBar 同一组、同一 tooltip 与回调）：
  /// 裸图标，不装胶囊底。「编辑标签」只在 hero 一处（见 [_buildAppBar]）。
  List<Widget> _headerActions(List<CollectionMemberEntry> arranged) {
    return <Widget>[
      FushiIconButtonControl(
        key: const ValueKey<String>('collection_detail_rename'),
        tooltip: t.rename_collection,
        icon: const FushiIcon(FushiIcons.rename),
        onPressed: renameDetailCollection,
      ),
      if (_sort != CollectionMemberSort.manual)
        FushiIconButtonControl(
          key: const ValueKey<String>('collection_detail_header_save_order'),
          tooltip: t.collection_detail_save_order,
          icon: const FushiIcon(FushiIcons.download),
          onPressed: () => _saveViewOrder(arranged),
        ),
      if (_artScrapeAvailable) ...<Widget>[
        FushiIconButtonControl(
          key: const ValueKey<String>('collection_detail_art_scrape'),
          tooltip: t.collection_art_scrape_action,
          icon: const FushiIcon(FushiIcons.imageSearch),
          onPressed: _scrapeArt,
        ),
        FushiIconButtonControl(
          key: const ValueKey<String>('collection_detail_art_clear'),
          tooltip: t.collection_art_scrape_clear,
          icon: const FushiIcon(FushiIcons.deleteSweep),
          onPressed: _clearArt,
        ),
      ],
      FushiIconButtonControl(
        key: const ValueKey<String>('collection_detail_delete'),
        tooltip: t.delete_collection,
        icon: const FushiIcon(FushiIcons.delete),
        onPressed: _delete,
      ),
    ];
  }

  bool get _artScrapeAvailable {
    final CollectionArtScrape? art = widget.artScrape;
    return art != null && art.enabled && CollectionArtScrape.appliesTo(_rows);
  }

  void _afterArtChanged() {
    widget.onChanged();
    if (mounted) setState(() {});
  }

  Future<void> _scrapeArt() => widget.artScrape!.scrape(
    context,
    collectionId: widget.collection.id,
    onChanged: _afterArtChanged,
  );

  Future<void> _clearArt() => widget.artScrape!.clear(
    context,
    collectionId: widget.collection.id,
    onChanged: _afterArtChanged,
  );

  /// 海报 / 面板取色用的封面：「继续」会打开的那本（与旧 hero 叠层的前排同一
  /// 判据），没有就按合集序第一本有封面的；都没有为 null（面板按合集名折色相）。
  Widget? _heroCover(List<CollectionMemberEntry> entries) {
    final CollectionMemberEntry? current = pickContinueMember(entries);
    if (_coverOf(current) case final Widget cover) return cover;
    for (final CollectionMemberEntry e in entries) {
      if (_coverOf(e) case final Widget cover) return cover;
    }
    return null;
  }

  /// 成员纯封面：[MediaCollectionGridDetailPage.memberInfoOf] 的封面优先，其次
  /// [MediaCollectionGridDetailPage.memberCoverOf]。
  Widget? _coverOf(CollectionMemberEntry? e) {
    if (e == null) return null;
    return e.info?.cover ??
        widget.memberCoverOf?.call(e.row.mediaType, e.row.entryKey);
  }

  /// [_coverOf] 再按该成员判定 NSFW 包一层模糊（头部封面用；取色 / 宽高比仍用
  /// [_coverOf] 的原图源，只用于配色、不显示原图）。
  Widget? _displayCoverOf(CollectionMemberEntry? e) {
    final Widget? cover = _coverOf(e);
    if (e == null || cover == null) return cover;
    final String mediaType = e.row.mediaType;
    final String entryKey = e.row.entryKey;
    final MediaNsfwTarget? target = widget.memberNsfwOf != null
        ? widget.memberNsfwOf!(mediaType, entryKey)
        : MediaNsfwTarget.collectionMember(mediaType, entryKey);
    return MediaNsfwCover(target: target, child: cover);
  }

  /// [_heroCover] 那一本，按它判定 NSFW 后的显示版本。
  Widget? _heroDisplayCover(List<CollectionMemberEntry> entries) {
    final CollectionMemberEntry? current = pickContinueMember(entries);
    if (_coverOf(current) != null) return _displayCoverOf(current);
    for (final CollectionMemberEntry e in entries) {
      if (_coverOf(e) != null) return _displayCoverOf(e);
    }
    return null;
  }

  ImageProvider? _heroCoverImage(List<CollectionMemberEntry> entries) {
    final Widget? cover = _heroCover(entries);
    return cover == null ? null : fushiCoverImageOf(cover);
  }

  Widget _buildScroll(
    List<CollectionMemberEntry> entries,
    List<CollectionMemberEntry> arranged,
    Map<String, Widget> cards,
    bool filtered,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool redesign = shellRedesignActive(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 840;
        // 重设计外壳宽屏：左右两栏——左栏是合集信息（大封面 / 名称 / 统计 /
        // 标签，紧凑海报 hero，[_buildPosterHero]），右栏是工具条 + 成员网格，两栏
        // 顶端对齐、整页一起滚。窄屏（与海报面板同一宽窄判据）仍是头部在上。
        final bool twoPane =
            redesign &&
            MediaPosterDetailLayout.isWide(context, constraints.maxWidth);
        // 库页布局为拼贴 / 规整色块时整页换色块语言：左栏是封面取色的合集块，
        // 成员排库页同款单本色块（[_buildBlockGrid]）；封面网格布局保持两栏 +
        // 封面网格（2026-11-13 用户：「和封面网格要做区分」）。
        final bool blockStyle = redesign && _blockStyleFor(entries);
        // 色块成员墙只在网格视图、非排序模式（排序模式仍是拖排封面网格）。
        final bool blockGrid =
            blockStyle &&
            _viewMode == CollectionMemberViewMode.grid &&
            !_reordering;
        // 海报面板：左右页边与 hero / 漫画作品页的区块同一条竖线。
        final double hPad = redesign
            ? (twoPane ? tokens.spacing.section : tokens.spacing.page)
            : (wide ? tokens.spacing.card * 1.5 : 12);
        final double sideWidth = twoPane
            ? (constraints.maxWidth * 0.24).clamp(300.0, 380.0)
            : 0;
        final double gutter = twoPane ? tokens.spacing.section * 1.5 : 0;
        // 成员区（工具条 / 网格 / 列表）自己的左右页边：两栏时由外层统一留。
        final double sPad = twoPane ? 0 : hPad;
        final ({int finished, int counted, double? progress}) summary =
            summarizeCollectionMembers(entries);
        // 封面前排 = 正在读的那本（看到第五本就显示第五本），其余按合集序垫在
        // 后面当叠层。
        final CollectionMemberEntry? current = pickContinueMember(entries);
        final List<Widget> covers = <Widget>[
          if (_displayCoverOf(current) case final Widget cover) cover,
          for (final CollectionMemberEntry e in entries)
            if (!identical(e, current))
              if (_displayCoverOf(e) case final Widget cover) cover,
        ];
        // 任何排序下都可拖：拖一次即把当前显示顺序连同这次移动存为手动序
        // （[_onReorder]）。此前只在「手动」下才进拖排网格，而默认排序是卷号，
        // 没手动排过的合集一律拖不动、长按还弹菜单（用户实报「不能拖动排序」）。
        // 排序模式下筛选 / 列表也进拖排网格（筛选态由 [mergeCollectionOrder] 保序合并）。
        final bool canReorder =
            _reordering ||
            (!filtered &&
                !_selecting &&
                _viewMode == CollectionMemberViewMode.grid);
        // 成员一律排封面网格（书 / 漫画竖封面为主、书名两行 + 进度条，与书架
        // 同一套卡），不再排横向小色块：色块里封面只占一角、背后还压着被裁
        // 一半的水印字，成员看不清（2026-11-12 用户「很丑重新设计」）。

        // 旧 hero 卡（墨水屏）：叠层封面与成员卡同一套条目材质，按成员主类型
        // （数量最多的那类）选。
        final ShelfCoverMaterial? heroMaterial = _dominantCoverMaterial(_rows);
        final Widget heroCard = CollectionDetailHeroCard(
          name: _name,
          memberCount: entries.length,
          finished: widget.memberInfoOf == null ? null : summary.finished,
          progress: summary.progress,
          covers: covers.take(3).toList(),
          tags: _collectionTags,
          wide: wide,
          onEditTags: _editCollectionTags,
          // 整块点按 = 接着看 / 读 current（不放按钮，hero 上有播放标记示意）。
          continueLabel: current?.displayTitle,
          onContinue: current == null || widget.onOpenMember == null
              ? null
              : () => widget.onOpenMember!(
                  current.row.mediaType,
                  current.row.entryKey,
                ),
        );
        final Widget hero = heroMaterial == null
            ? heroCard
            : ShelfCoverMaterialScope(material: heroMaterial, child: heroCard);

        final double available =
            constraints.maxWidth - hPad * 2 - sideWidth - gutter;
        const double spacing = 12;
        // 重设计外壳：宽屏右栏目标列宽 200（180～220 间按栏宽两端对齐铺满），
        // 窄屏排两到三列；墨水屏照旧跟书架网格同一档。
        final double targetWidth = !redesign
            ? readerShelfGridExtentForLayout(
                mediaWidth: MediaQuery.sizeOf(context).width,
                contentWidth: available,
              )
            : twoPane
            ? 200
            : math.max(110.0, (available - spacing * 2) / 3);
        final ({int columns, double cardWidth}) layout = unifiedShelfCardLayout(
          availableWidth: available > 0 ? available : targetWidth,
          targetWidth: targetWidth,
          spacing: spacing,
        );
        // 游戏合集：卡盒竖长 1:1.6 + 封面下文字块，按真实行高算格子比例（书卡
        // 比例装不下，卡片会溢出格子）。书 / 漫画：与书架网格同一公式
        // （[shelfBookCellAspectRatio]，封面区恒为书封比例；成员卡自带标准内边距，
        // 本页不包 [ShelfGridCellInset]）——固定卡槽比例在格宽偏离设计值时封面
        // 两侧会露出材质衬底。
        final bool gameDomain = _isGameDomain();
        final double memberAspect = gameDomain
            ? layout.cardWidth /
                  (layout.cardWidth / kShelfGameCaseAspectRatio +
                      ShelfCardMeta.heightFor(context))
            : shelfBookCellAspectRatio(
                cellWidth: layout.cardWidth,
                inset: tokens.spacing.rowVertical,
                footerHeight: ShelfCardMeta.heightFor(context),
              );

        final List<Widget> slivers = <Widget>[
          if (!redesign)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(hPad, tokens.spacing.gap, hPad, 0),
              sliver: SliverToBoxAdapter(
                child: FushiStaggeredEntrance(index: 0, child: hero),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              sPad,
              // 两栏时工具条顶端与左栏封面顶端对齐；头部在上时隔一档卡片间距。
              twoPane ? 0 : tokens.spacing.card,
              sPad,
              tokens.spacing.gap,
            ),
            sliver: SliverToBoxAdapter(
              child: FushiStaggeredEntrance(
                index: 1,
                child: _buildToolbar(arranged, entries),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: sPad),
            sliver: SliverToBoxAdapter(child: _buildFilterPanel(entries)),
          ),
        ];

        if (arranged.isEmpty) {
          slivers.add(
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(tokens.spacing.card * 2),
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.filterOff,
                  message: t.collection_detail_filter_empty,
                  action: FushiTextButton(
                    key: const ValueKey<String>(
                      'collection_detail_clear_filters',
                    ),
                    onPressed: _clearFilters,
                    child: Text(t.library_filters_clear),
                  ),
                ),
              ),
            ),
          );
        } else if (blockGrid && _splitsByMetadata) {
          final List<CollectionMemberEntry> rich = <CollectionMemberEntry>[
            for (final CollectionMemberEntry e in arranged)
              if (_memberIsRich(e)) e,
          ];
          final List<CollectionMemberEntry> rest = <CollectionMemberEntry>[
            for (final CollectionMemberEntry e in arranged)
              if (!_memberIsRich(e)) e,
          ];
          // 分段时两段各是全序的子集，直拖重排关掉（排序模式仍可拖排全序）。
          if (rich.isNotEmpty) {
            slivers.add(
              _buildBlockGrid(
                hPad: sPad,
                bleed: hPad,
                arranged: rich,
                cards: cards,
                dragReorderable: false,
              ),
            );
          }
          if (rich.isNotEmpty && rest.isNotEmpty) {
            slivers.add(
              SliverToBoxAdapter(
                child: SizedBox(height: tokens.spacing.section),
              ),
            );
          }
          if (rest.isNotEmpty) {
            slivers.add(
              _buildPlainGrid(
                hPad: sPad,
                arranged: rest,
                cards: cards,
                columns: layout.columns,
                aspect: memberAspect,
                spacing: spacing,
              ),
            );
          }
        } else if (blockGrid) {
          slivers.add(
            _buildBlockGrid(
              hPad: sPad,
              bleed: hPad,
              arranged: arranged,
              cards: cards,
              dragReorderable: !filtered && !_selecting,
            ),
          );
        } else if (_viewMode == CollectionMemberViewMode.list && !canReorder) {
          slivers.add(
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: sPad),
              sliver: SliverList.builder(
                itemCount: arranged.length,
                itemBuilder: (BuildContext context, int i) =>
                    FushiStaggeredEntrance(
                      index: i,
                      child: _MemberListRow(
                        key: ValueKey<String>('member-row-${arranged[i].key}'),
                        entry: arranged[i],
                        selecting: _selecting,
                        selected: _selected.contains(arranged[i].key),
                        showStatus: widget.memberInfoOf != null,
                        onTap: () => _activate(arranged[i]),
                        onLongPress: () => _toggleSelected(arranged[i]),
                        longPressOpensMenu: !_selecting,
                        onMenu: (Offset p) =>
                            _showMemberMenu(arranged[i].row, p),
                      ),
                    ),
              ),
            ),
          );
        } else if (canReorder) {
          // 消缩放 2D 拖排网格（轻点 → 打开、鼠标按下拖 → 重排、长按 / 右键 →
          // 上下文菜单；排序模式下触屏按住即拖）。卡片包在 IgnorePointer 里，避免
          // 其内部 InkWell 的 long-press 与网格触摸手势争用竞技场。
          slivers.add(
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: sPad),
              sliver: SliverToBoxAdapter(
                child: FushiReorderableGrid(
                  itemCount: arranged.length,
                  crossAxisCount: layout.columns,
                  childAspectRatio: memberAspect,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                  feedbackBorderRadius: FushiBorderRadius.card,
                  reordering: _reordering,
                  keyForIndex: (int i) => ValueKey<String>(arranged[i].key),
                  onReorder: (int from, int to) =>
                      _onReorder(arranged, from, to),
                  onActivateItem: widget.onOpenMember == null
                      ? null
                      : (int i) => widget.onOpenMember!(
                          arranged[i].row.mediaType,
                          arranged[i].row.entryKey,
                        ),
                  onContextMenu: (int i, Offset globalPosition) =>
                      _showMemberMenu(arranged[i].row, globalPosition),
                  itemBuilder: (BuildContext context, int i) =>
                      FushiStaggeredEntrance(
                        index: i,
                        child: _HoverableMemberCard(
                          child: cards[arranged[i].key]!,
                        ),
                      ),
                ),
              ),
            ),
          );
        } else {
          slivers.add(
            _buildPlainGrid(
              hPad: sPad,
              arranged: arranged,
              cards: cards,
              columns: layout.columns,
              aspect: memberAspect,
              spacing: spacing,
            ),
          );
        }
        if (widget.trackingSection case final Widget section) {
          slivers.add(
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                sPad,
                tokens.spacing.section,
                sPad,
                0,
              ),
              sliver: SliverToBoxAdapter(child: section),
            ),
          );
        }
        // 底部留白：多选浮动栏出现时不压住末行。
        final double bottomGap = _selecting || _reordering
            ? 120
            : tokens.spacing.card * 2;
        if (twoPane) {
          final double top =
              MediaQuery.paddingOf(context).top + tokens.spacing.gap;
          // 2026-10 动效：左栏各块与工具条 / 成员错峰进场。
          return FushiEntranceScope(
            child: MediaPosterDetailLayout(
              controller: _scroll,
              bottomPadding: bottomGap,
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsetsDirectional.fromSTEB(hPad, top, hPad, 0),
                  sliver: SliverCrossAxisGroup(
                    slivers: <Widget>[
                      SliverConstrainedCrossAxis(
                        maxExtent: sideWidth,
                        sliver: SliverToBoxAdapter(
                          // 左栏充当 hero：滚出页头下沿后页头才淡入合集名。
                          child: MediaPosterHeroExtent(
                            leading: top,
                            child: _buildPosterHero(
                              entries: entries,
                              summary: summary,
                              side: true,
                            ),
                          ),
                        ),
                      ),
                      SliverConstrainedCrossAxis(
                        maxExtent: gutter,
                        sliver: const SliverToBoxAdapter(),
                      ),
                      SliverCrossAxisExpanded(
                        flex: 1,
                        sliver: SliverMainAxisGroup(slivers: slivers),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        if (redesign) {
          // 2026-10 动效：头部 / 工具条 / 成员错峰进场（头部内部各块自带错峰）。
          return FushiEntranceScope(
            child: MediaPosterDetailLayout(
              controller: _scroll,
              bottomPadding: bottomGap,
              header: _buildPosterHero(
                entries: entries,
                summary: summary,
                side: false,
              ),
              slivers: slivers,
            ),
          );
        }
        slivers.add(SliverToBoxAdapter(child: SizedBox(height: bottomGap)));
        // 2026-10 动效：hero / 工具条 / 成员错峰进场。
        return FushiEntranceScope(
          child: CustomScrollView(controller: _scroll, slivers: slivers),
        );
      },
    );
  }

  /// 合集 hero（重设计外壳）：与漫画作品页 / 书详情 / 视频系列同一个海报 hero
  /// （[MediaPosterDetailHero]，2026-11-16 所有者「合集样式都改成这种」）——背景带
  /// 在上（合集自己 / 借最前那卷的横版海报，没有就封面重模糊垫底）、封面斜放压过
  /// 背景带下沿、艺术字；「合集」小标签、合集名、「共 N 项 · 已读完 x/y」，再下是
  /// 类型 / 评分 / 年份胶囊、可展开简介，动作行是同尺寸图标钮（「编辑标签」，放
  /// 不下收进「⋯」），已挂标签 chip 在页脚。封面是「正在读」那本（没有就合集序
  /// 第一本有封面的）；游戏套卡盒材质。卷数已在统计行里，不重复成胶囊；改名 /
  /// 下载 / 删除留在页头裸图标。宽屏左栏（[side]）走紧凑版式
  /// （[MediaPosterDetailHero.compact]）并按栏裁圆角。不放继续入口（2026-11-12
  /// 用户「合集右上角那些去掉」）。
  Widget _buildPosterHero({
    required List<CollectionMemberEntry> entries,
    required ({int finished, int counted, double? progress}) summary,
    required bool side,
  }) {
    final Widget? cover = _heroCover(entries);
    final String stats = <String>[
      t.collection_detail_member_count(n: entries.length),
      if (widget.memberInfoOf != null)
        t.collection_detail_finished_count(
          done: summary.finished,
          total: entries.length,
        ),
    ].join(' · ');
    final ({FushiSeriesMeta meta, String? summary})? series =
        _collectionSeries();
    final FushiSeriesMeta? meta = series?.meta;
    final bool gameCase = _isGameDomain();
    // 游戏卡盒不按封面图比例量（卡盒比例固定），其余按封面真实比例显示全。
    final ImageProvider? coverImage = cover == null
        ? null
        : fushiCoverImageOf(cover);
    // 显示用按该成员判定 NSFW 包一层模糊；取色 / 宽高比仍用原图源。
    final Widget posterContent =
        _heroDisplayCover(entries) ??
        const MediaDetailCoverPlaceholder(icon: FushiIcons.collection);
    final double? rating = meta?.rating;
    final int? year = meta?.year;
    final Widget hero = MediaPosterDetailHero(
      key: const ValueKey<String>('collection_detail_series_hero'),
      compact: side,
      kicker: t.collection_detail_kicker,
      title: _name,
      originalTitle: stats,
      originalTitleKey: const ValueKey<String>('collection_detail_hero_meta'),
      poster: SizedBox.expand(
        key: const ValueKey<String>('collection_detail_header_cover'),
        child: gameCase
            ? ShelfCoverMaterialScope(
                material: ShelfCoverMaterial.gameCase,
                child: ShelfCoverFrame(child: posterContent),
              )
            : posterContent,
      ),
      posterImage: gameCase ? null : coverImage,
      backdrop: meta?.backdrop,
      backdropFallback: coverImage,
      logo: meta?.logo,
      logoSemanticsName: _name,
      pills: <MediaDetailChip>[
        if (rating != null)
          MediaDetailChip(
            '★ ${rating.toStringAsFixed(1)}',
            tone: MediaDetailChipTone.primary,
            key: const ValueKey<String>('collection_detail_series_rating'),
          ),
        if (year != null) MediaDetailChip('$year', icon: FushiIcons.calendar),
        for (final String genre in meta?.genres ?? const <String>[])
          MediaDetailChip(genre),
      ],
      summary: series?.summary,
      summaryKey: const ValueKey<String>('collection_detail_scrape_summary'),
      selectableSummary: false,
      more: MediaDetailMoreButton(
        buttonKey: const ValueKey<String>('collection_detail_more'),
        items: <MediaDetailMenuItem>[
          MediaDetailMenuItem(
            key: const ValueKey<String>('collection_detail_edit_tags'),
            icon: FushiIcons.tag,
            label: t.collection_detail_edit_tags,
            onSelected: _editCollectionTags,
          ),
        ],
      ),
      footer: _collectionTags.isEmpty
          ? null
          : CollectionTagRow(
              key: const ValueKey<String>('collection_detail_tag_row'),
              tags: _collectionTags,
              onEditTags: _editCollectionTags,
              showEditButton: false,
            ),
    );
    return KeyedSubtree(
      key: const ValueKey<String>('collection_detail_poster_hero'),
      child: side
          ? ShellClip(radius: FushiM3eShape.containerLargeRadius, child: hero)
          : hero,
    );
  }

  /// 合集的系列资料：合集自己有刮削资料 / 背景图就用自己的，否则借最前那卷（继续
  /// 会打开的那本）的刮削资料与横版海报；都没有为 null（头部保持原样）。只读
  /// [_reload] 预取的字段，零 IO。
  ///
  /// 背景带优先级：合集自己的背景图 > 「获取各卷封面与横幅」下到的系列横幅
  /// （[_artBannerPath]，用户在本合集上主动取的、系列级）> 借来那卷的背景图 >
  /// 没有（hero 用封面模糊垫底）。
  ({FushiSeriesMeta meta, String? summary})? _collectionSeries() {
    final String? backdropPath = _backdropPath;
    final String? logoPath = _logoPath;
    final String? bannerPath = _artBannerPath;
    final ImageProvider? banner = bannerPath == null
        ? null
        : resizedFileImage(File(bannerPath));
    final FushiSeriesMeta? own = collectionSeriesMeta(
      scrape: _scrapeMeta,
      backdrop: backdropPath == null
          ? null
          : resizedFileImage(File(backdropPath)),
      logo: logoPath == null ? null : resizedFileImage(File(logoPath)),
      countLabel: null,
    );
    if (own != null) {
      final String? summary = _scrapeMeta?.summary?.trim();
      return (
        meta: own.backdrop == null && banner != null
            ? own.withBackdrop(banner)
            : own,
        summary: summary == null || summary.isEmpty ? null : summary,
      );
    }
    final ({FushiSeriesMeta meta, String? summary})? borrowed = widget
        .collectionSeriesFallback
        ?.call();
    if (borrowed == null) {
      return banner == null
          ? null
          : (meta: FushiSeriesMeta(backdrop: banner), summary: null);
    }
    final String? summary = borrowed.summary?.trim();
    return (
      meta: banner == null ? borrowed.meta : borrowed.meta.withBackdrop(banner),
      summary: summary == null || summary.isEmpty ? null : summary,
    );
  }

  /// 色块成员墙（库页布局为拼贴 / 规整色块）：与书架库墙单本书同一套色块与
  /// 尺寸规则（[SliverFushiCoverBlocks] 等尺寸规整块、目标宽
  /// [kFushiCoverBlockTargetWidthSingle]、两端对齐）。每格是同一个
  /// [_MemberGridTile]（轻点打开 / 长按菜单 / 右键 / 多选勾选），卡片包
  /// [FushiCoverBlockScope] 由调用方的成员卡自己换成色块视觉；桌面直拖重排经
  /// [LibraryDragReorderScope]，与库页色块布局同一套。
  Widget _buildBlockGrid({
    required double hPad,
    required double bleed,
    required List<CollectionMemberEntry> arranged,
    required Map<String, Widget> cards,
    required bool dragReorderable,
  }) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      sliver: LibraryDragReorderScope(
        enabled: dragReorderable,
        onReorder: (int from, int to) => _onReorder(arranged, from, to),
        child: SliverFushiCoverBlocks(
          itemCount: arranged.length,
          targetWidth: kFushiCoverBlockTargetWidthSingle,
          // 悬停放大越进页边距：色块左右与工具条 / 搜索框同一条竖线，不再缩进。
          hoverBleed: bleed,
          itemBuilder: (BuildContext context, int i, FushiCoverBlockSize size) {
            final CollectionMemberEntry e = arranged[i];
            return LibraryReorderCell(
              index: i,
              child: _MemberGridTile(
                key: ValueKey<String>('member-tile-${e.key}'),
                block: size,
                selecting: _selecting,
                selected: _selected.contains(e.key),
                onTap: () => _activate(e),
                onLongPress: () => _toggleSelected(e),
                longPressOpensMenu: !_selecting,
                onMenu: (Offset p) => _showMemberMenu(e.row, p),
                child: FushiCoverBlockScope(
                  size: size,
                  child: ShelfGridCellInset(inset: 0, child: cards[e.key]!),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 普通封面网格成员墙（封面网格布局，或窄屏分段的下段）。
  Widget _buildPlainGrid({
    required double hPad,
    required List<CollectionMemberEntry> arranged,
    required Map<String, Widget> cards,
    required int columns,
    required double aspect,
    required double spacing,
  }) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          childAspectRatio: aspect,
          crossAxisSpacing: spacing,
          mainAxisSpacing: spacing,
        ),
        itemCount: arranged.length,
        itemBuilder: (BuildContext context, int i) {
          final CollectionMemberEntry e = arranged[i];
          return FushiStaggeredEntrance(
            index: i,
            child: _MemberGridTile(
              key: ValueKey<String>('member-tile-${e.key}'),
              selecting: _selecting,
              selected: _selected.contains(e.key),
              onTap: () => _activate(e),
              onLongPress: () => _toggleSelected(e),
              longPressOpensMenu: !_selecting,
              onMenu: (Offset p) => _showMemberMenu(e.row, p),
              child: cards[e.key]!,
            ),
          );
        },
      ),
    );
  }

  /// 成员全是游戏（卡盒竖长 1:1.6）。
  bool _isGameDomain() =>
      _rows.isNotEmpty &&
      _rows.every(
        (MediaCollectionItemRow r) => r.mediaType == MediaKind.game.dbValue,
      );

  void _activate(CollectionMemberEntry entry) {
    if (_selecting) {
      _toggleSelected(entry);
      return;
    }
    widget.onOpenMember?.call(entry.row.mediaType, entry.row.entryKey);
  }

  void _clearFilters() {
    setState(() {
      _search.clear();
      _tagFilter = <int>{};
      _statusFilter = null;
    });
  }

  /// 成员区工具条：搜索 · 筛选 · 排序 · 网格 / 列表 · 多选。
  Widget _buildToolbar(
    List<CollectionMemberEntry> arranged,
    List<CollectionMemberEntry> entries,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int activeFilters =
        _tagFilter.length + (_statusFilter == null ? 0 : 1);
    final bool hasFilterDims =
        widget.memberInfoOf != null ||
        entries.any((CollectionMemberEntry e) => e.tagIds.isNotEmpty);
    final Widget search = FushiSearchField(
      fieldKey: const ValueKey<String>('collection_detail_search'),
      controller: _search,
      focusNode: _searchFocus,
      hintText: t.collection_detail_search_hint,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {},
      onClear: () => setState(_search.clear),
    );
    final Widget actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (hasFilterDims)
          FushiBadgeControl(
            isLabelVisible: activeFilters > 0,
            label: Text('$activeFilters'),
            child: FushiIconButton(
              key: const ValueKey<String>('collection_detail_filter'),
              icon: FushiIcons.filterList,
              tooltip: t.shelf_toolbar_filters,
              selected: _filtersOpen,
              onTap: () => setState(() => _filtersOpen = !_filtersOpen),
            ),
          ),
        _buildSortMenu(arranged),
        _ViewModeToggle(
          mode: _viewMode,
          onChanged: (CollectionMemberViewMode m) =>
              setState(() => _viewMode = m),
        ),
        FushiIconButton(
          key: const ValueKey<String>('collection_detail_select'),
          icon: _selecting ? FushiIcons.close : FushiIcons.checklist,
          tooltip: _selecting
              ? MaterialLocalizations.of(context).closeButtonTooltip
              : t.batch_select,
          selected: _selecting,
          onTap: _toggleSelecting,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        if (c.maxWidth >= 640) {
          return Row(
            children: <Widget>[
              SizedBox(
                width: (c.maxWidth * 0.4).clamp(240.0, 420.0),
                child: search,
              ),
              const Spacer(),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            search,
            SizedBox(height: tokens.spacing.gap),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        );
      },
    );
  }

  Widget _buildSortMenu(List<CollectionMemberEntry> arranged) {
    String label(CollectionMemberSort s) => switch (s) {
      CollectionMemberSort.manual => t.collection_detail_sort_manual,
      CollectionMemberSort.volume => t.collection_detail_sort_volume,
      CollectionMemberSort.added => t.collection_detail_sort_added,
      CollectionMemberSort.read => t.collection_detail_sort_read,
    };
    IconData icon(CollectionMemberSort s) => switch (s) {
      CollectionMemberSort.manual => FushiIcons.dragIndicator,
      CollectionMemberSort.volume => FushiIcons.sortByAlpha,
      CollectionMemberSort.added => FushiIcons.history,
      CollectionMemberSort.read => FushiIcons.schedule,
    };
    return FushiMenuAnchor(
      menuChildren: <Widget>[
        for (final CollectionMemberSort s in CollectionMemberSort.values)
          // 阅读时间排序要靠调用方给的最后阅读时刻。
          if (s != CollectionMemberSort.read || widget.memberInfoOf != null)
            MenuItemButton(
              key: ValueKey<String>('collection_detail_sort_${s.name}'),
              leadingIcon: FushiIcon(icon(s), size: 20),
              trailingIcon: s == _sort
                  ? const FushiIcon(FushiIcons.check, size: 20)
                  : null,
              autofocus: s == _sort,
              onPressed: () => _setSort(s),
              child: Text(label(s)),
            ),
        const FushiDivider(),
        MenuItemButton(
          key: const ValueKey<String>('collection_detail_save_order'),
          leadingIcon: const FushiIcon(FushiIcons.download, size: 20),
          onPressed: _sort == CollectionMemberSort.manual
              ? null
              : () => _saveViewOrder(arranged),
          child: Text(t.collection_detail_save_order),
        ),
        if (widget.collectionAiSettings case final AiSettingsSource settings)
          MenuItemButton(
            key: const ValueKey<String>('collection_detail_sort_ai'),
            leadingIcon: const FushiIcon(FushiIcons.ai, size: 20),
            onPressed: () => _sortWithAi(settings),
            child: Text(t.collection_sort_ai),
          ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) =>
          FushiIconButton(
            key: const ValueKey<String>('collection_detail_sort'),
            icon: FushiIcons.sort,
            tooltip: t.sort_by,
            selected: _sort != CollectionMemberSort.volume,
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
    );
  }

  /// 筛选面板（展开时）：阅读状态（有成员信息时）+ 成员身上出现过的标签。
  Widget _buildFilterPanel(List<CollectionMemberEntry> entries) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Set<int> present = <int>{
      for (final CollectionMemberEntry e in entries) ...e.tagIds,
    };
    final List<BookTagRow> tags = <BookTagRow>[
      for (final BookTagRow tag in _allTags)
        if (present.contains(tag.id)) tag,
    ];
    String statusLabel(ShelfReadStatus s) => switch (s) {
      ShelfReadStatus.unread => t.shelf_filter_read_status_unread,
      ShelfReadStatus.reading => t.shelf_filter_read_status_reading,
      ShelfReadStatus.finished => t.shelf_filter_read_status_finished,
    };
    final Widget panel = !_filtersOpen
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
            child: Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (widget.memberInfoOf != null)
                  for (final ShelfReadStatus s in ShelfReadStatus.values)
                    FushiTagToggleChip(
                      key: ValueKey<String>(
                        'collection_detail_status_${s.name}',
                      ),
                      label: statusLabel(s),
                      color: scheme.primary,
                      state: _statusFilter == s
                          ? TagCheckState.all
                          : TagCheckState.none,
                      onTap: () => setState(
                        () => _statusFilter = _statusFilter == s ? null : s,
                      ),
                    ),
                for (final BookTagRow tag in tags)
                  FushiTagToggleChip(
                    key: ValueKey<String>('collection_detail_tag_${tag.id}'),
                    label: tag.name,
                    color: Color(tag.colorValue),
                    state: _tagFilter.contains(tag.id)
                        ? TagCheckState.all
                        : TagCheckState.none,
                    onTap: () => setState(() {
                      final Set<int> next = Set<int>.of(_tagFilter);
                      if (!next.remove(tag.id)) next.add(tag.id);
                      _tagFilter = next;
                    }),
                  ),
                if (_tagFilter.isNotEmpty || _statusFilter != null)
                  FushiTextButton(
                    onPressed: () => setState(() {
                      _tagFilter = <int>{};
                      _statusFilter = null;
                    }),
                    child: Text(t.library_filters_clear),
                  ),
              ],
            ),
          );
    return AnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.enter,
      alignment: Alignment.topCenter,
      child: panel,
    );
  }

  /// 多选底部浮动操作栏（M3E floating toolbar；spring 从底部进出）。Apple 走
  /// iOS 编辑态的玻璃底栏 [BatchActionBar]（「已选 n 项」+ 全选 / 反选 + 动作
  /// 字形），退出编辑仍由工具栏的选择开关 / 返回键负责。
  Widget _buildSelectionBar(List<CollectionMemberEntry> arranged) {
    if (isGlassDesign(context)) return _buildAppleSelectionBar(arranged);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool hasSelection = _selected.isNotEmpty;
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette = fushiFloatingToolbarPalette(context);
    final Widget countPill = FushiFloatingPill(
      color: palette.container,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIconButtonControl(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const FushiIcon(FushiIcons.close),
            onPressed: _endSelection,
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: Text(
              t.batch_selected_count(n: _selected.length),
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: palette.foreground),
            ),
          ),
        ],
      ),
    );
    final Widget toolbar = FushiFloatingToolbar(
      variant: FushiFloatingToolbarVariant.vibrant,
      groups: <List<FushiToolbarItem>>[
        <FushiToolbarItem>[
          FushiToolbarItem(
            key: const ValueKey<String>('collection_detail_batch_tag'),
            icon: FushiIcons.tag,
            label: t.tag_label,
            onPressed: hasSelection ? _batchTag : null,
          ),
          if (widget.onSetMembersCompleted != null) ...<FushiToolbarItem>[
            FushiToolbarItem(
              key: const ValueKey<String>('collection_detail_batch_read'),
              icon: FushiIcons.success,
              label: t.book_mark_completed_action,
              onPressed: hasSelection ? () => _batchSetCompleted(true) : null,
            ),
            FushiToolbarItem(
              key: const ValueKey<String>('collection_detail_batch_unread'),
              icon: FushiIcons.radioUnchecked,
              label: t.book_mark_uncompleted_action,
              onPressed: hasSelection ? () => _batchSetCompleted(false) : null,
            ),
          ],
          FushiToolbarItem(
            key: const ValueKey<String>('collection_detail_batch_move'),
            icon: FushiIcons.moveFile,
            label: t.collection_detail_move_to,
            onPressed: hasSelection ? _batchMove : null,
          ),
          FushiToolbarItem(
            key: const ValueKey<String>('collection_detail_batch_remove'),
            icon: FushiIcons.removeCircle,
            label: t.collection_remove_member,
            onPressed: hasSelection ? _batchRemove : null,
          ),
        ],
      ],
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: tokens.spacing.card,
      child: FushiChromeReveal(
        visible: _selecting,
        from: AxisDirection.down,
        child: Center(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              if (c.maxWidth >= 640) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    countPill,
                    SizedBox(width: tokens.spacing.gap),
                    toolbar,
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  countPill,
                  SizedBox(height: tokens.spacing.gap),
                  toolbar,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Apple 多选底栏：[BatchActionBar] 玻璃胶囊；全选 / 反选以当前筛选后可见的
  /// [arranged] 为域（被筛掉的成员不受影响），动作与 M3E 工具栏同 key 同语义。
  Widget _buildAppleSelectionBar(List<CollectionMemberEntry> arranged) {
    final bool hasSelection = _selected.isNotEmpty;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: FushiChromeReveal(
        visible: _selecting,
        from: AxisDirection.down,
        child: BatchActionBar(
          selectedCount: _selected.length,
          onSelectAll: () => setState(() {
            _selected.addAll(<String>[
              for (final CollectionMemberEntry e in arranged) e.key,
            ]);
          }),
          onInvertSelection: () => setState(() {
            for (final CollectionMemberEntry e in arranged) {
              if (!_selected.remove(e.key)) _selected.add(e.key);
            }
          }),
          actions: <Widget>[
            FushiIconButton(
              key: const ValueKey<String>('collection_detail_batch_tag'),
              icon: FushiIcons.tag,
              tooltip: t.tag_label,
              enabled: hasSelection,
              onTap: _batchTag,
            ),
            if (widget.onSetMembersCompleted != null) ...<Widget>[
              FushiIconButton(
                key: const ValueKey<String>('collection_detail_batch_read'),
                icon: FushiIcons.success,
                tooltip: t.book_mark_completed_action,
                enabled: hasSelection,
                onTap: () => _batchSetCompleted(true),
              ),
              FushiIconButton(
                key: const ValueKey<String>('collection_detail_batch_unread'),
                icon: FushiIcons.radioUnchecked,
                tooltip: t.book_mark_uncompleted_action,
                enabled: hasSelection,
                onTap: () => _batchSetCompleted(false),
              ),
            ],
            FushiIconButton(
              key: const ValueKey<String>('collection_detail_batch_move'),
              icon: FushiIcons.moveFile,
              tooltip: t.collection_detail_move_to,
              enabled: hasSelection,
              onTap: _batchMove,
            ),
            FushiIconButton(
              key: const ValueKey<String>('collection_detail_batch_remove'),
              icon: FushiIcons.removeCircle,
              tooltip: t.collection_remove_member,
              enabled: hasSelection,
              onTap: _batchRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// 成员卡是否套着条目材质（墨水屏下材质整体退场，仍走旧的罩层 / 描边反馈）。
bool _hasCoverMaterial(BuildContext context, Widget card) =>
    card is ShelfCoverMaterialScope && !isEinkTheme(context);

/// 网格 / 列表切换：M3E 连接式按钮组（选中段形变）/ Apple 分段控件。
/// 成员媒体类型 → 条目材质：书 / 字幕书 = 光面书皮、视频 = 光面海报、游戏 =
/// 透明卡盒；未知类型不套材质。
ShelfCoverMaterial? _coverMaterialFor(String mediaType) {
  switch (MediaKind.tryParse(mediaType)) {
    case MediaKind.epub:
    case MediaKind.srt:
      return ShelfCoverMaterial.glossyBook;
    case MediaKind.video:
      return ShelfCoverMaterial.glossyPoster;
    case MediaKind.game:
      return ShelfCoverMaterial.gameCase;
    case null:
      return null;
  }
}

/// 合集主类型的条目材质：成员里数量最多的媒体类型（并列取先出现的）经
/// [_coverMaterialFor] 映射；没有成员 / 类型都不认识时为 null。
ShelfCoverMaterial? _dominantCoverMaterial(List<MediaCollectionItemRow> rows) {
  final Map<ShelfCoverMaterial, int> counts = <ShelfCoverMaterial, int>{};
  ShelfCoverMaterial? best;
  for (final MediaCollectionItemRow r in rows) {
    final ShelfCoverMaterial? m = _coverMaterialFor(r.mediaType);
    if (m == null) continue;
    final int n = (counts[m] ?? 0) + 1;
    counts[m] = n;
    if (best == null || n > counts[best]!) best = m;
  }
  return best;
}

class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.mode, required this.onChanged});

  final CollectionMemberViewMode mode;
  final ValueChanged<CollectionMemberViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: adaptiveSegmentedButton<CollectionMemberViewMode>(
        context: context,
        segments: <ButtonSegment<CollectionMemberViewMode>>[
          ButtonSegment<CollectionMemberViewMode>(
            value: CollectionMemberViewMode.grid,
            tooltip: t.collection_detail_view_grid,
            icon: const FushiIcon(
              FushiIcons.gridView,
              size: 18,
              key: ValueKey<String>('collection_detail_view_grid'),
            ),
          ),
          ButtonSegment<CollectionMemberViewMode>(
            value: CollectionMemberViewMode.list,
            tooltip: t.collection_detail_view_list,
            icon: const FushiIcon(
              FushiIcons.viewAgenda,
              size: 18,
              key: ValueKey<String>('collection_detail_view_list'),
            ),
          ),
        ],
        selected: <CollectionMemberViewMode>{mode},
        onSelectionChanged: (Set<CollectionMemberViewMode> v) {
          if (v.isNotEmpty) onChanged(v.first);
        },
      ),
    );
  }
}

/// 长按的分流：[longPressOpensMenu] 时弹上下文菜单（锚点取 [context] 盒子中心），
/// 否则走 [onLongPress]（多选态切换勾选）。
///
/// 触屏没有右键，[ContextMenuTrigger] 只认鼠标按钮；此前非拖排网格 / 列表的长按恒
/// 为「进多选」，触屏用户在合集里根本拿不到与库页同一份卡片菜单（iPad 用户实报
/// 「合集里的漫画长按缺少各种功能」）。进多选另有工具条按钮。
VoidCallback _memberLongPressHandler(
  BuildContext context, {
  required bool longPressOpensMenu,
  required VoidCallback onLongPress,
  required ValueChanged<Offset> onMenu,
}) {
  if (!longPressOpensMenu) return onLongPress;
  return () {
    final RenderObject? box = context.findRenderObject();
    onMenu(
      box is RenderBox && box.hasSize
          ? box.localToGlobal(box.size.center(Offset.zero))
          : Offset.zero,
    );
  };
}

/// 非拖排网格里的一格：轻点打开（多选态切换勾选）、长按弹卡片菜单（多选态切换
/// 勾选）、右键菜单；卡片本体仍包在 [IgnorePointer] 里（手势统一由本格接管），
/// 多选态叠一枚勾选圆钮。
class _MemberGridTile extends StatelessWidget {
  const _MemberGridTile({
    required this.child,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.longPressOpensMenu,
    required this.onMenu,
    this.block,
    super.key,
  });

  final Widget child;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool longPressOpensMenu;
  final ValueChanged<Offset> onMenu;

  /// 非 null = 封面色块格（[FushiCoverBlockSize]）：选中罩 / 墨水波纹按色块圆角
  /// 画，悬停是整块抬升（[FushiHoverLift]，卡片本体被 IgnorePointer 屏蔽，色块
  /// 自己的悬停收不到指针），不垫灰底板。
  final FushiCoverBlockSize? block;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockSize? block = this.block;
    if (block == null) return _buildTile(context, null);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) => FushiHoverLift(
        enabled: !selecting,
        scale: 1.02,
        builder: (BuildContext context, bool _) => _buildTile(
          context,
          BorderRadius.all(
            Radius.circular(fushiCoverBlockRadius(block, c.maxHeight)),
          ),
        ),
      ),
    );
  }

  /// [blockRadius] 非 null = 色块格（见 [block]）。
  Widget _buildTile(BuildContext context, BorderRadius? blockRadius) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool material =
        blockRadius != null || _hasCoverMaterial(context, child);
    final BorderRadius radius = blockRadius ?? tokens.radii.cardRadius;
    return ContextMenuTrigger(
      onInvoke: (Offset p) => runWithContextMenuAnchor(p, () => onMenu(p)),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          // 材质卡的悬停 / 按压反馈是卡片自己的抬升 + 扫光，不再垫灰底板。
          overlayColor: material
              ? const WidgetStatePropertyAll<Color>(Colors.transparent)
              : null,
          splashFactory: material ? NoSplash.splashFactory : null,
          onTap: onTap,
          onLongPress: _memberLongPressHandler(
            context,
            longPressOpensMenu: longPressOpensMenu,
            onLongPress: onLongPress,
            onMenu: onMenu,
          ),
          // 卡片在 [_HoverableMemberCard] 里被 IgnorePointer 挡住，自己那份按压
          // 缩放 / 封面扫光收不到指针，由本格代收（只旁观指针，不与 InkWell 抢）。
          child: FushiPressScale(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _HoverableMemberCard(
                  hoverOverlay: blockRadius == null,
                  child: child,
                ),
                if (selecting) ...<Widget>[
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          color: selected
                              ? scheme.primary.withValues(alpha: 0.18)
                              : Colors.transparent,
                          border: Border.all(
                            color: selected
                                ? scheme.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IgnorePointer(
                      child: _SelectionMark(selected: selected),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表形态的一行：小封面 + 名称 + 进度 + 阅读状态；多选态行尾勾选。
class _MemberListRow extends StatelessWidget {
  const _MemberListRow({
    required this.entry,
    required this.selecting,
    required this.selected,
    required this.showStatus,
    required this.onTap,
    required this.onLongPress,
    required this.longPressOpensMenu,
    required this.onMenu,
    super.key,
  });

  final CollectionMemberEntry entry;
  final bool selecting;
  final bool selected;
  final bool showStatus;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool longPressOpensMenu;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final CollectionMemberInfo? info = entry.info;
    final double? progress = info == null
        ? null
        : (info.completed ? 1.0 : info.progress);
    final String? status = !showStatus || info == null
        ? null
        : switch (info.readStatus) {
            ShelfReadStatus.unread => t.shelf_filter_read_status_unread,
            ShelfReadStatus.reading => t.shelf_filter_read_status_reading,
            ShelfReadStatus.finished => t.shelf_filter_read_status_finished,
          };
    final Widget thumb = ClipRRect(
      borderRadius: BorderRadius.circular(apple ? 6 : 10),
      child: SizedBox(
        width: 44,
        height: 66,
        child:
            info?.cover ??
            ColoredBox(
              color: scheme.secondaryContainer,
              child: Center(
                child: FushiIcon(
                  FushiIcons.books,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
      ),
    );
    return ContextMenuTrigger(
      onInvoke: (Offset p) => runWithContextMenuAnchor(p, () => onMenu(p)),
      child: Padding(
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        child: Material(
          color: selected
              ? scheme.secondaryContainer
              : apple
              ? Colors.transparent
              : scheme.surfaceContainerLow,
          borderRadius: apple
              ? FushiM3eShape.smallRadius
              : FushiM3eShape.cardRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: _memberLongPressHandler(
              context,
              longPressOpensMenu: longPressOpensMenu,
              onLongPress: onLongPress,
              onMenu: onMenu,
            ),
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.gap * 1.25),
              child: Row(
                children: <Widget>[
                  thumb,
                  SizedBox(width: tokens.spacing.gap * 1.5),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          entry.displayTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.type.listTitle.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (progress != null) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap),
                          ClipRRect(
                            borderRadius: FushiBorderRadius.chip,
                            // 与书架封面进度条（[CoverProgressStrip]）同一套配色：
                            // 在读 primary、读完换完成色（MD3 tertiary / Apple 系统
                            // 绿），平直静态形态。此前恒为 primary 的 M3E 波浪条：
                            // vibrant 方案下 primary 是高彩度蓝紫，一列「读完」行
                            // 全是同一道饱和蓝，读作与主题无关的固定蓝（2026-10-09
                            // 反馈），且波浪常驻动画。
                            child: FushiLinearProgressIndicator(
                              key: const ValueKey<String>(
                                'collection_member_list_progress',
                              ),
                              value: progress.clamp(0.0, 1.0),
                              minHeight: 4,
                              wavy: false,
                              color:
                                  info?.readStatus == ShelfReadStatus.finished
                                  ? (apple
                                        ? appleColorsOf(context).success
                                        : scheme.tertiary)
                                  : (apple
                                        ? appleColorsOf(context).accent
                                        : scheme.primary),
                              backgroundColor: apple
                                  ? appleColorsOf(context).tertiaryFill
                                  : scheme.secondaryContainer,
                            ),
                          ),
                        ],
                        if (status != null) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap / 2),
                          Text(
                            progress != null && progress > 0 && progress < 1
                                ? '$status · ${(progress * 100).round()}%'
                                : status,
                            style: tokens.type.metadata,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (selecting)
                    _SelectionMark(selected: selected)
                  else
                    Builder(
                      builder: (BuildContext buttonContext) =>
                          FushiIconButtonControl(
                            tooltip: t.shelf_toolbar_more,
                            icon: const FushiIcon(FushiIcons.more),
                            onPressed: () {
                              final RenderBox box =
                                  buttonContext.findRenderObject()!
                                      as RenderBox;
                              onMenu(
                                box.localToGlobal(box.size.center(Offset.zero)),
                              );
                            },
                          ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 多选勾选圆钮：选中实心主色 + 勾，未选空心描边（选中时弹一下）。
class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: selected ? 1 : 0.88,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.release,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected
              ? scheme.primary
              : scheme.surface.withValues(alpha: 0.85),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
            width: 2,
          ),
        ),
        child: selected
            ? FushiIcon(FushiIcons.check, size: 18, color: scheme.onPrimary)
            : null,
      ),
    );
  }
}

/// 空合集：M3E 大号形状底图标 + 一句话 + 返回。
class _EmptyCollection extends StatelessWidget {
  const _EmptyCollection({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card * 2),
        child: FushiStaggeredEntrance(
          index: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  color: apple
                      ? appleColorsOf(context).secondaryFill
                      : scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(apple ? 56 : 36),
                ),
                child: FushiIcon(
                  FushiIcons.collection,
                  size: 52,
                  color: apple
                      ? appleColorsOf(context).secondaryLabel
                      : scheme.onTertiaryContainer,
                ),
              ),
              SizedBox(height: tokens.spacing.card),
              Text(
                t.collection_empty,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.collection_detail_empty_hint,
                textAlign: TextAlign.center,
                style: tokens.type.listSubtitle,
              ),
              SizedBox(height: tokens.spacing.card),
              FushiFilledButton(
                key: const ValueKey<String>('collection_detail_empty_back'),
                onPressed: onBack,
                child: Text(
                  MaterialLocalizations.of(context).backButtonTooltip,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 成员卡的指针悬停反馈壳：卡片本体仍被 [IgnorePointer] 屏蔽（长按拖拽手势竞技场
/// 决策不变），悬停与指针位置由 [FushiHoverLiftRelay] 的 [MouseRegion]（默认
/// opaque，自身参与命中测试）代收再往下传——卡片照常走库页同一套抬升 / 扫光 /
/// 接触阴影 / 3D 倾斜视差（反馈 bsbJ4OVa8o：此前只代收悬停位，倾斜层拿不到指针
/// 位置，合集里的书卡永远是平的）。触摸/手柄路径零变化。
class _HoverableMemberCard extends StatelessWidget {
  const _HoverableMemberCard({required this.child, this.hoverOverlay = true});

  final Widget child;

  /// false = 不画悬停灰罩（色块格的悬停是外层整块抬升）。
  final bool hoverOverlay;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final bool material = _hasCoverMaterial(context, child);
    return FushiHoverLiftRelay(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovering) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          IgnorePointer(child: child),
          if (hovering && hoverOverlay && !material)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  // eink 半透明 hover 罩合成抖动灰 → 改描边反馈。
                  decoration: eink
                      ? BoxDecoration(
                          border: Border.all(color: tokens.surfaces.outline),
                          borderRadius: tokens.radii.cardRadius,
                        )
                      : BoxDecoration(
                          color: tokens.surfaces.onSurface.withValues(
                            alpha: 0.08,
                          ),
                          borderRadius: tokens.radii.cardRadius,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 成员卡上下文菜单动作。
enum _MemberMenuAction { open, remove }
