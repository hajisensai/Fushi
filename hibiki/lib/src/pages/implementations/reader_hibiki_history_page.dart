import 'dart:async' show unawaited;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/drag_drop/card_drop_registry.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/media/video/video_subtitle_attach.dart';
import 'package:hibiki/src/pages/implementations/book_drag_target.dart';
import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:hibiki/src/media/collections/batch_combine.dart';
import 'package:hibiki/src/media/collections/collection_grouping.dart';
import 'package:hibiki/src/media/collections/shelf_sort.dart';
import 'package:hibiki/src/media/collections/collection_shelf_row.dart';
import 'package:hibiki/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:hibiki/src/sync/cloud_remote_book_client.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_download_progress_badge.dart';
import 'package:hibiki/src/sync/remote_cover_image.dart';
import 'package:hibiki/src/sync/remote_book_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/utils.dart';

part 'reader_history/card_widgets.part.dart';
part 'reader_history/remote.part.dart';
part 'reader_history/video.part.dart';
part 'reader_history/books.part.dart';
part 'reader_history/dialogs.part.dart';

/// Stable gamepad/keyboard focus ids for the shelf chrome, used both to place
/// [HibikiFocusTarget]s and to wire directional anchors (see
/// [HibikiFocusController.registerDirectionalAnchor]). Kept as constants (not
/// derived per-instance ids) precisely so anchors can point at them by name.
const HibikiFocusId kShelfImportFocusId = HibikiFocusId('reader-shelf-import');

class ReaderHibikiHistoryPage extends HistoryReaderPage {
  const ReaderHibikiHistoryPage({
    this.remoteBookClientLoader,
    this.remoteBookDownloadDestination,
    this.remoteBookImporter,
    this.remoteAudiobookFetcher,
    this.remoteAudiobookImporter,
    super.key,
  });

  final Future<RemoteBookClient?> Function()? remoteBookClientLoader;
  final Future<File> Function(RemoteBookInfo book)?
      remoteBookDownloadDestination;
  // 返回本地入库的 bookKey（生产路径来自 EpubImporter.importFromPath）。
  final Future<String?> Function(File file)? remoteBookImporter;

  /// 测试注入：按远端 bookKey 下载有声书包，返回包文件（绕过真实互联后端）。
  final Future<File> Function(String remoteBookKey)? remoteAudiobookFetcher;

  /// 测试注入：导入有声书包（package + bookKeyOverride），绕过真实解包落盘。
  final Future<void> Function(File package, String? bookKeyOverride)?
      remoteAudiobookImporter;

  /// 测试钩子：按 mediaIdentifier 确定性打开书（绕开离屏不可靠的焦点卡激活——
  /// 焦点+Enter 在离屏 IndexedStack 下偶发不触发书卡 onTap）。走与书卡 onTap 同一
  /// 路径 appModel.openMedia。仅 debug/profile build 在 build 注册。
  @visibleForTesting
  static Future<void> Function(String mediaIdentifier)? debugOpenBook;

  @override
  BaseHistoryPageState<BaseHistoryPage> createState() =>
      _ReaderHibikiHistoryPageState();
}

class _ReaderHibikiHistoryPageState<T extends HistoryReaderPage>
    extends HistoryReaderPageState {
  ReaderHibikiHistoryPage get _pageWidget => widget as ReaderHibikiHistoryPage;

  @override
  MediaType get mediaType => mediaSource.mediaType;

  @override
  ReaderHibikiSource get mediaSource => ReaderHibikiSource.instance;

  Future<Map<String, _AudiobookInfo>>? _batchAudiobookInfoFuture;
  Map<String, _AudiobookInfo> _batchAudiobookInfoResult = const {};

  /// 拖拽导入：书卡登记表，范型 = bookKey。书卡经 [CardDropZone] 注册自身屏幕
  /// 矩形，落点命中后据此找到目标书 key（字幕/音频附加到该书）。
  final CardDropRegistry<String> _cardDropRegistry = CardDropRegistry<String>();

  /// 库内 part 文件（extension）改状态的入口：扩展不被视作 State 子类实例成员，
  /// 直接调 @protected 的 setState 会报 invalid_use_of_protected_member。由本 State
  /// 子类持有的这个转发器统一承接，零行为变化（仅转发）。
  void _rebuild(VoidCallback fn) => setState(fn);

  Future<Map<String, _AudiobookInfo>> _loadAllAudiobookInfo() async {
    final repo = AudiobookRepository(appModel.database);
    final allAudiobooks = await repo.buildBookKeyMap();
    final result = <String, _AudiobookInfo>{};
    final healthFutures = <String, Future<AudiobookHealth>>{};
    for (final entry in allAudiobooks.entries) {
      healthFutures[entry.key] = repo.resolveHealth(entry.value);
    }
    final healths = <String, AudiobookHealth>{};
    await Future.wait(healthFutures.entries.map((e) async {
      healths[e.key] = await e.value;
    }));
    for (final entry in allAudiobooks.entries) {
      result[entry.key] = _AudiobookInfo(
        hasAudiobook: true,
        healthKind: healths[entry.key]?.kind ?? HealthKind.notApplicable,
      );
    }
    _batchAudiobookInfoResult = result;
    return result;
  }

  _AudiobookInfo _getAudiobookInfo(String bookKey) {
    return _batchAudiobookInfoResult[bookKey] ??
        const _AudiobookInfo(
            hasAudiobook: false, healthKind: HealthKind.notApplicable);
  }

  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};

  /// 多选态合集整选（块2）：选中合集 id 集，与散卡选中集 [_selectedKeys] 并存。
  /// 组合三档（块3）与批量解散/删除（块4）都读这两个集。
  final Set<int> _selectedCollectionIds = <int>{};

  /// 当前渲染成横排行的合集 id 列表（[_buildBodyWithSrtBooks] 每帧写入），供
  /// 全选 / 反选把可见合集纳入整选集。
  List<int> _visibleCollectionIds = const <int>[];
  List<MediaItem> _visibleEpubBooks = const [];
  List<SrtBook> _visibleSrtBooks = const [];
  Map<String, String> _epubCoverUrisByBookKey = const {};
  // TODO-1191：书架 SRT 卡长按菜单「查看插画」的 EPUB-backing 门控真值。
  // 收录当前 `books`（hibikiBooksProvider 的全部 EpubBooks 行）解析出的 bookKey；
  // SRT 卡的 bookKey 命中此集合 = 有对应 EpubBooks 行（extractDir 存在），才对称
  // 展示「查看插画」。EPUB 未生成完（`srt_epub_not_ready`）的 SRT 书不在此集合，
  // 避免展示打不开的死项。生成型 EPUB（TextToEpub，无真实插图）仍展示，交由
  // IllustrationsViewerPage 的 `no_illustrations_found` 占位友好兜底。
  Set<String> _epubBackedBookKeys = const {};

  // 视频书单独分区：无 Riverpod provider，按需载入 state 并在导入后刷新。
  List<VideoBookRow> _videoBooks = const [];
  Future<List<VideoBookRow>>? _videoBooksFuture;
  Future<_RemoteBookState?>? _remoteBooksFuture;

  /// 排序交互重设计层次 A：当前排序方式（偏好 `shelf_sort_mode` 持久化，默认
  /// 最近阅读=历史序，现状零变化）。旧 `ShelfEntries.sortOrder` 手动权重已废弃。
  Future<void>? _shelfMapsFuture;
  ShelfSortMode _sortMode = ShelfSortMode.recent;

  /// 层次 C：`'mediaType|entryKey' → 该条目在其主折叠合集里的 sortIndex`（组内序
  /// 真相源，与详情页 `getCollectionItems` 同源）。
  Map<String, int> _memberSortIndex = const <String, int>{};

  /// 「导入时间」排序用：epub bookKey → importedAt 毫秒（MediaItem 不携带导入
  /// 时间；SRT 卡的 SrtBook 自带）。
  Map<String, int> _epubImportedAtByKey = const <String, int>{};

  /// 统一合集 Phase 4：书籍合集字典（id → 行）+ 条目折叠归属（'mediaType|entryKey' →
  /// 最小 collectionId），与上述映射同一次 [_loadShelfMaps] 预取，替代 Series 折叠。
  Map<int, MediaCollectionRow> _collectionsById =
      const <int, MediaCollectionRow>{};
  Map<String, int> _primaryCollectionByEntry = const <String, int>{};
  RemoteBookClient? _remoteBookClient;

  /// 正在下载中的远端书（key = book.title）。值为进度分数 0..1；收到首个
  /// onProgress 前为 null（不确定进度）。下载期间用它在卡片上替换下载按钮为进度
  /// 指示（#3：远端下载全程有进行中反馈，不再 await 完才弹一次提示）。
  final Map<String, double?> _downloadingBooks = <String, double?>{};

  VideoBookRepository get _videoRepo => VideoBookRepository(appModel.database);

  double _gridExtent(BuildContext context, BoxConstraints constraints) {
    return readerShelfGridExtentForLayout(
      mediaWidth: MediaQuery.sizeOf(context).width,
      contentWidth: constraints.maxWidth,
    );
  }

  void _refreshSrtBooks() {
    ref.invalidate(srtBooksProvider);
    _batchAudiobookInfoFuture = null;
    _batchAudiobookInfoResult = const {};
    _refreshRemoteBooks();
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      _selectedKeys.clear();
      _selectedCollectionIds.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
      _selectedCollectionIds.clear();
    });
  }

  void _toggleSelection(String key) {
    setState(() {
      if (!_selectedKeys.remove(key)) {
        _selectedKeys.add(key);
      }
    });
  }

  /// 块2：切换整合集选中（合集行头勾选框）。
  void _toggleCollectionSelection(int collectionId) {
    setState(() {
      if (!_selectedCollectionIds.remove(collectionId)) {
        _selectedCollectionIds.add(collectionId);
      }
    });
  }

  @override
  void dispose() {
    assert(() {
      ReaderHibikiHistoryPage.debugOpenBook = null;
      return true;
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<MediaItem>> books =
        ref.watch(hibikiBooksProvider(appModel.targetLanguage));
    assert(() {
      ReaderHibikiHistoryPage.debugOpenBook = (String mediaId) async {
        final List<MediaItem> items = ref
                .read(hibikiBooksProvider(appModel.targetLanguage))
                .valueOrNull ??
            const <MediaItem>[];
        MediaItem? target;
        for (final MediaItem m in items) {
          if (m.mediaIdentifier == mediaId) {
            target = m;
            break;
          }
        }
        if (target == null) {
          return;
        }
        await appModel.openMedia(
          ref: ref,
          mediaSource: target.getMediaSource(appModel: appModel),
          item: target,
        );
      };
      return true;
    }());
    final AsyncValue<Set<String>?> filteredIds =
        ref.watch(filteredBookIdsProvider);
    final allTags = ref.watch(allTagsProvider);

    // BUG-250: 书架批量选择模式（[_selectionMode]）活在本 tab 内容里，不是独立
    // route。顶层 HomePage 的 PopScope 对它无感，返回键会直接弹掉 root route 退
    // 出 App，而不是退出选择模式。这里像查词 tab（home_dictionary_page）一样用
    // 嵌套 PopScope 拦截：选择模式开启时 canPop=false，返回先退出选择模式。
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (_selectionMode) _exitSelectionMode();
      },
      child: HibikiFileDropTarget(
        debugLabel: 'reader-shelf',
        onDrop: _handleShelfDrop,
        child: CardDropScope<String>(
          registry: _cardDropRegistry,
          child: DesktopContentLayout(
            kind: DesktopContentKind.readerShelf,
            child: Column(
              children: [
                if (!isCupertinoPlatform(context)) _buildPageHeader(),
                _buildTagBar(allTags.valueOrNull ?? const []),
                Expanded(
                  child: books.when(
                    data: (bookList) {
                      _batchAudiobookInfoFuture ??= _loadAllAudiobookInfo();
                      _videoBooksFuture ??= _loadVideoBooks();
                      _remoteBooksFuture ??= _loadRemoteBooks();
                      _shelfMapsFuture ??= _loadShelfMaps();
                      final Set<String>? filterSet = filteredIds.valueOrNull;
                      final List<MediaItem> filtered;
                      if (filterSet == null) {
                        filtered = bookList;
                      } else {
                        filtered = bookList.where((item) {
                          final String? key =
                              _parseBookKey(item.mediaIdentifier);
                          return key != null && filterSet.contains(key);
                        }).toList();
                      }
                      return FutureBuilder<Map<String, _AudiobookInfo>>(
                        future: _batchAudiobookInfoFuture,
                        builder: (context, abSnapshot) =>
                            FutureBuilder<List<VideoBookRow>>(
                          future: _videoBooksFuture,
                          builder: (context, videoSnapshot) =>
                              FutureBuilder<_RemoteBookState?>(
                            future: _remoteBooksFuture,
                            builder: (context, remoteSnapshot) =>
                                FutureBuilder<void>(
                              future: _shelfMapsFuture,
                              builder: (context, _) =>
                                  buildBody(filtered, remoteSnapshot),
                            ),
                          ),
                        ),
                      );
                    },
                    error: (error, stack) => buildError(
                      error: error,
                      stack: stack,
                      refresh: () {
                        _refreshSrtBooks();
                        ref.invalidate(
                          hibikiBooksProvider(appModel.targetLanguage),
                        );
                      },
                    ),
                    loading: () => buildLoading(),
                  ),
                ),
                if (_selectionMode) _buildBatchActionBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagBar(List<BookTagRow> allTags) {
    return HibikiTagFilterBar(
      tags: allTags,
      onToggleFilter: _toggleFilter,
      onReorder: _reorderTags,
      selectionMode: _selectionMode,
      onToggleSelectionMode: _toggleSelectionMode,
      // 排序交互重设计层次 A：「排序方式」菜单（原「整理」按钮位置；整理页已删）。
      // 分组管理走批量「组合成合集」+ 合集详情页（改名/删除/移出成员/一键排序）。
      sortMode: _sortMode,
      sortModeLabel: _sortModeLabel,
      onSortModeChanged: _setSortMode,
      onTagsChanged: () => ref.invalidate(bookTagMapProvider),
    );
  }

  Widget _buildPageHeader() {
    return HibikiPageHeader(
      title: t.books,
      actions: <Widget>[
        // 宽窗（非 compact）时动作展开成「图标+文字」药丸（与视频 tab 页头一致，
        // 用户 mockup：导入书籍 / 来源 / 合集 / 阅读统计带文字外显）；窄窗回落纯图标。
        mediaSource.buildBookImportButton(
          context: context,
          ref: ref,
          appModel: appModel,
          focusId: kShelfImportFocusId,
          label: t.srt_import,
        ),
        _headerAction(
          tooltip: t.media_source_manage_title,
          icon: Icons.folder_copy_outlined,
          onTap: _openManageSources,
        ),
        // 视频导入入口**只属于视频 tab**（HomeVideoPage），书架不放视频导入——
        // 书架是书的地方。这里保留编译期常量门控（默认关）只为旧调试路径，运行时
        // 实验开关不再在书架放出视频导入（用户反馈：书架不该有视频导入入口）。
        if (kVideoImportEnabled)
          _headerAction(
            tooltip: t.video_import_action,
            icon: Icons.movie_outlined,
            onTap: _openVideoImport,
          ),
        _headerAction(
          tooltip: t.collections,
          icon: Icons.collections_bookmark_outlined,
          onTap: _openCollections,
        ),
        _headerAction(
          tooltip: t.reading_statistics,
          icon: Icons.bar_chart_outlined,
          onTap: _openReadingStatistics,
        ),
      ],
    );
  }

  Widget _headerAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return HibikiIconButton(
      tooltip: tooltip,
      // 页头动作宽窗展开文字（tooltip 即标签文案）；窄窗由组件自动回落纯图标。
      label: tooltip,
      icon: icon,
      onTap: onTap,
    );
  }

  /// 打开「管理来源」对话框（书籍来源库）。关闭后失效书架 provider 刷新列表
  /// （扫描可能新增 EPUB）。
  Future<void> _openManageSources() async {
    await showAppDialog<void>(
      context: context,
      builder: (_) => const MediaSourcesDialog(mediaKind: 'book'),
    );
    if (!mounted) return;
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    ref.invalidate(srtBooksProvider);
  }

  void _openCollections() {
    Navigator.push(
      context,
      adaptivePageRoute(builder: (_) => const CollectionsPage()),
    );
  }

  void _openReadingStatistics() {
    Navigator.push(
      context,
      adaptivePageRoute(builder: (_) => const ReadingStatisticsPage()),
    );
  }

  /// 一次性预取书架排序/分组所需映射：合集字典、折叠归属、组内 sortIndex、
  /// epub 导入时间，外加偏好里的排序方式。
  Future<void> _loadShelfMaps() async {
    _sortMode = ShelfSortMode.fromName(appModel.prefsRepo.shelfSortModeName);
    final List<MediaCollectionRow> collections =
        await appModel.database.getAllMediaCollections();
    final Map<String, int> primaryMap =
        await appModel.database.getPrimaryCollectionIdByEntry();
    // 层次 C：条目在其主折叠合集里的 sortIndex（只记归属合集的行，与 primaryMap
    // 同口径；详情页拖完 onChanged 重载本映射，库页行立即同序）。
    final Map<String, int> memberSortIndex = <String, int>{};
    for (final MediaCollectionRow c in collections) {
      final List<MediaCollectionItemRow> members =
          await appModel.database.getCollectionItems(c.id);
      for (final MediaCollectionItemRow m in members) {
        final String key = '${m.mediaType}|${m.entryKey}';
        if (primaryMap[key] == c.id) memberSortIndex[key] = m.sortIndex;
      }
    }
    final List<EpubBookRow> epubRows =
        await appModel.database.getAllEpubBooks();
    _epubImportedAtByKey = <String, int>{
      for (final EpubBookRow r in epubRows) r.bookKey: r.importedAt,
    };
    _memberSortIndex = memberSortIndex;
    _collectionsById = <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in collections) c.id: c,
    };
    _primaryCollectionByEntry = primaryMap;
  }

  /// 用户切换排序方式：立即重排 + 偏好持久化（跨启动记住）。
  void _setSortMode(ShelfSortMode mode) {
    if (mode == _sortMode) return;
    setState(() => _sortMode = mode);
    unawaited(appModel.prefsRepo.setShelfSortModeName(mode.name));
  }

  /// 合集行折叠开关：`setPref` 先同步刷内存缓存，setState 重建即读到新值；
  /// 落库 fire-and-forget（`collapsed_collection_ids`，书架/视频页共用）。
  void _toggleCollectionCollapsed(int collectionId) {
    final PreferencesRepository prefs = appModel.prefsRepo;
    final Set<int> ids = prefs.collapsedCollectionIds;
    if (!ids.remove(collectionId)) ids.add(collectionId);
    unawaited(prefs.setCollapsedCollectionIds(ids));
    setState(() {});
  }

  String _sortModeLabel(ShelfSortMode mode) => switch (mode) {
        ShelfSortMode.recent => t.sort_recent_read,
        ShelfSortMode.title => t.sort_title,
        ShelfSortMode.imported => t.sort_imported,
      };

  /// 每本书（bookKey → reader_positions.updatedAt 毫秒）的最后阅读时间；
  /// 关书时经 [ReaderHibikiSource.onSourceExit] 与书列表同点失效（BUG-777）。
  Map<String, int> get _lastReadAtByBookKey =>
      ref.watch(bookLastReadAtProvider).valueOrNull ?? const <String, int>{};

  /// 组级排序键：散卡取条目自身；合集行取成员聚合（recent/imported 取成员 max、
  /// title 取合集名）。recentScore = 最后阅读时间（[_lastReadAtByBookKey]，
  /// EPUB/SRT 同走 bookKey），没读过退 importedAt——与视频页 watch-stats 语义
  /// 镜像（BUG-777：旧的 -历史序名次实为 SRT 表序+EPUB 导入序，假 recency）；
  /// importedAt 用 [CollectionOrderingItem.importedAt]（epub 走
  /// [_epubImportedAtByKey]，srt 自带）。
  ShelfSortKey _shelfGroupSortKey(CollectionGroup<_ShelfBookSlot> group) {
    String titleOf(_ShelfBookSlot s) =>
        s.srt?.title ?? s.epub?.title ?? s.remote?.title ?? '';
    int recentOf(CollectionOrderingItem<_ShelfBookSlot> it) {
      // 远端占位卡无本地阅读进度：退化到注入时编码的目录序（负 importedAt），稳定
      // 排在本地条目之后（详见 [_ShelfBookSlot.remote]）。
      if (it.payload.remote != null) return it.importedAt;
      final String? bookKey = it.payload.srt?.bookKey ??
          _parseBookKey(it.payload.epub!.mediaIdentifier);
      return _lastReadAtByBookKey[bookKey] ?? it.importedAt;
    }

    final MediaCollectionRow? collection = group.collection;
    if (collection == null) {
      final CollectionOrderingItem<_ShelfBookSlot> it = group.coverItem;
      return ShelfSortKey(
        recentScore: recentOf(it),
        title: titleOf(it.payload),
        importedAt: it.importedAt,
        tieKey: '${it.mediaType}|${it.entryKey}',
      );
    }
    int recent = 0;
    int imported = 0;
    for (final CollectionOrderingItem<_ShelfBookSlot> it in group.items) {
      final int r = recentOf(it);
      if (r > recent) recent = r;
      if (it.importedAt > imported) imported = it.importedAt;
    }
    return ShelfSortKey(
      recentScore: recent,
      title: collection.name,
      importedAt: imported,
      tieKey: 'c${collection.id}',
    );
  }

  /// 多端库联合视图 §2.3 任务10：按 (name, collectionType) 自然键把远端合集归属解析成
  /// 本地合集 id（折叠归属同「最小 collectionId」规则，多个同键取最小）；本地无此合集则
  /// 返 null（远端占位散卡降级，不硬造合集行）。
  int? _resolveLocalCollectionId(String name, String type) {
    int? best;
    for (final MediaCollectionRow c in _collectionsById.values) {
      if (c.name == name && c.collectionType == type) {
        if (best == null || c.id < best) best = c.id;
      }
    }
    return best;
  }

  void _toggleFilter(int tagId) {
    final current = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (current.contains(tagId)) {
      current.remove(tagId);
    } else {
      current.add(tagId);
    }
    ref.read(selectedTagIdsProvider.notifier).state = current;
  }

  Future<void> _reorderTags(int oldIndex, int newIndex) async {
    final tags = ref.read(allTagsProvider).valueOrNull;
    if (tags == null) return;
    final reordered = List<BookTagRow>.from(tags);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    final orderedIds = reordered.map((t) => t.id).toList();
    await ref.read(appProvider).database.reorderTags(orderedIds);
    ref.invalidate(allTagsProvider);
  }

  /// 给某媒体（epub/srt/video）打标签的共用流程：已有则提示并返回；否则写 DB →
  /// 失效相关 provider → 成功提示。三种媒体只差「标签表 provider / DB 方法 / filtered
  /// provider / 成功文案」，作参数注入（[alreadyHas] 由各调用方按自己的标签 map 算好，
  /// [successMsg] 区分书籍 `tag_added_to_book` vs 视频 `tag_added_to_video`）。
  Future<void> _addTagToMedia({
    required bool alreadyHas,
    required BookTagRow tag,
    required Future<void> Function() addToDb,
    required List<ProviderOrFamily> invalidate,
    required String successMsg,
  }) async {
    if (alreadyHas) {
      HibikiToast.show(msg: t.tag_already_on_book(name: tag.name));
      return;
    }
    await addToDb();
    for (final ProviderOrFamily p in invalidate) {
      ref.invalidate(p);
    }
    if (mounted) {
      HibikiToast.show(msg: successMsg);
    }
  }

  Future<void> _addTagToBook(String bookKey, BookTagRow tag) async {
    final existing = ref.read(bookTagMapProvider).valueOrNull;
    await _addTagToMedia(
      alreadyHas: existing?[bookKey]?.any((t) => t.id == tag.id) ?? false,
      tag: tag,
      addToDb: () =>
          ref.read(appProvider).database.addTagToBook(bookKey, tag.id),
      invalidate: <ProviderOrFamily>[
        bookTagMapProvider,
        filteredBookIdsProvider
      ],
      successMsg: t.tag_added_to_book(name: tag.name),
    );
  }

  Future<void> _addTagToSrtBook(int srtBookId, BookTagRow tag) async {
    final existing = ref.read(srtBookTagMapProvider).valueOrNull;
    await _addTagToMedia(
      alreadyHas: existing?[srtBookId]?.any((t) => t.id == tag.id) ?? false,
      tag: tag,
      addToDb: () =>
          ref.read(appProvider).database.addTagToSrtBook(srtBookId, tag.id),
      invalidate: <ProviderOrFamily>[
        srtBookTagMapProvider,
        filteredSrtBookIdsProvider,
      ],
      successMsg: t.tag_added_to_book(name: tag.name),
    );
  }

  /// 某媒体卡上挂的标签列：标签 map 为空 / 该 key 无标签都返回 null，否则渲染
  /// [_adaptiveTagColumn]。三种媒体（epub/srt/video）只差「watch 哪个标签 provider +
  /// key 类型」，故各 caller 自己 `ref.watch(provider).valueOrNull`（保响应式订阅）后
  /// 把解析好的 map 传进来，空/列逻辑收口于此泛型 helper。
  Widget? _tagLabelsFromMap<K>(Map<K, List<BookTagRow>>? tagMap, K key) {
    if (tagMap == null) return null;
    final tags = tagMap[key];
    if (tags == null || tags.isEmpty) return null;
    return _adaptiveTagColumn(tags);
  }

  Widget? _buildTagLabels(String bookKey) =>
      _tagLabelsFromMap(ref.watch(bookTagMapProvider).valueOrNull, bookKey);

  Widget buildBody(
    List<MediaItem> books, [
    AsyncSnapshot<_RemoteBookState?>? remoteSnapshot,
  ]) {
    final List<SrtBook> srtBooks =
        ref.watch(srtBooksProvider).valueOrNull ?? const [];
    return _buildBodyWithSrtBooks(books, srtBooks, remoteSnapshot);
  }

  /// UI v2：书架顶部「继续阅读 hero + 书库概览」条（对齐视频页）。
  ///
  /// 数据边界（诚实外显）：hero = 在读（0<position<duration）EPUB 中「最后阅读
  /// 时间」（[bookLastReadAtProvider]，即 reader_positions.updatedAt）最新者，
  /// 显示「已读 x%」；无候选整块只剩统计。BUG-777：旧实现取列表第一本在读书，
  /// 但列表序 = getAllEpubBooks 的 importedAt 倒序，选中的是「最近导入」而非
  /// 「最近阅读」的书。统计 = 总数（EPUB+SRT）/ 在读 / 读完（后两格按 EPUB
  /// 进度；SRT 卡无统一进度数据，不硬造）。宽 >=720 并排、窄屏堆叠。
  Widget _buildShelfOverviewSection(
    List<MediaItem> epubBooks,
    List<SrtBook> srtBooks,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<MediaItem> inProgress = <MediaItem>[];
    int reading = 0;
    int finished = 0;
    for (final MediaItem item in epubBooks) {
      final int duration = item.duration;
      if (duration <= 0) continue;
      if (item.position >= duration) {
        finished++;
      } else if (item.position > 0) {
        reading++;
        inProgress.add(item);
      }
    }
    final MediaItem? hero = mostRecentlyReadCandidate(
      inProgress,
      (MediaItem item) =>
          _lastReadAtByBookKey[_parseBookKey(item.mediaIdentifier)] ?? 0,
    );
    final Widget stats = _buildShelfOverviewStats(
      total: epubBooks.length + srtBooks.length,
      reading: reading,
      finished: finished,
      tokens: tokens,
    );
    final Widget? heroCard =
        hero == null ? null : _buildContinueReadingHero(hero, tokens);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        0,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (heroCard == null) return stats;
          final bool wide = constraints.maxWidth >= 720;
          if (wide) {
            // IntrinsicHeight 必须有：SliverToBoxAdapter 下主轴无界，裸
            // Row(stretch) 会强制无限高崩溃（与视频页同一根因，对抗审查确认）。
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 3, child: heroCard),
                  SizedBox(width: tokens.spacing.gap + 4),
                  Expanded(flex: 2, child: stats),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              heroCard,
              SizedBox(height: tokens.spacing.gap),
              stats,
            ],
          );
        },
      ),
    );
  }

  /// 继续阅读 hero：封面缩略 + 标题 + 已读 % 。整卡点击开书。
  Widget _buildContinueReadingHero(MediaItem hero, HibikiDesignTokens tokens) {
    final int percent = hero.duration > 0
        ? ((hero.position / hero.duration) * 100).clamp(0, 100).round()
        : 0;
    return HibikiCard(
      key: const ValueKey<String>('reader_shelf_continue_hero'),
      focusId: const HibikiFocusId('reader-shelf-continue-hero'),
      onTap: () async {
        final MediaSource source = hero.getMediaSource(appModel: appModel);
        await appModel.openMedia(ref: ref, mediaSource: source, item: hero);
      },
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: HibikiBorderRadius.card,
            child: SizedBox(
              width: 56,
              height: 84,
              child: FadeInImage(
                imageErrorBuilder: (_, __, ___) =>
                    _coverPlaceholderIcon(Icons.menu_book_outlined),
                placeholder: MemoryImage(kTransparentImage),
                image: mediaSource.getDisplayThumbnailFromMediaItem(
                  appModel: appModel,
                  item: hero,
                ),
                fit: BoxFit.cover,
              ),
            ),
          ),
          SizedBox(width: tokens.spacing.gap + 4),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(t.book_continue_reading, style: tokens.type.sectionLabel),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  hero.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  t.book_read_progress(percent: percent),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Icon(
            Icons.play_circle_filled,
            size: 36,
            color: tokens.surfaces.primary,
          ),
        ],
      ),
    );
  }

  /// 书库概览统计三格：总数 / 在读 / 读完。
  Widget _buildShelfOverviewStats({
    required int total,
    required int reading,
    required int finished,
    required HibikiDesignTokens tokens,
  }) {
    Widget cell(String label, int value) => Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('$value', style: tokens.type.pageTitle),
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata,
              ),
            ],
          ),
        );
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
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.book_library_overview, style: tokens.type.sectionLabel),
            SizedBox(height: tokens.spacing.gap),
            Row(
              children: <Widget>[
                cell(t.video_stat_total_videos, total),
                cell(t.shelf_stat_reading, reading),
                cell(t.video_stat_completed, finished),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBodyWithSrtBooks(
    List<MediaItem> books,
    List<SrtBook> allSrtBooks,
    AsyncSnapshot<_RemoteBookState?>? remoteSnapshot,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Map<String, String> epubCoverUrisByBookKey = {};
    // TODO-1191：`books` 是 hibikiBooksProvider 的全部 EpubBooks 行；解析出的
    // bookKey 全集即「有 EpubBooks 行」的真值，供 SRT 卡「查看插画」门控用。
    final Set<String> epubBackedBookKeys = {};
    for (final MediaItem item in books) {
      final String? key = _parseBookKey(item.mediaIdentifier);
      if (key != null) epubBackedBookKeys.add(key);
      final String? imageUrl = item.imageUrl;
      if (key != null && imageUrl != null && imageUrl.isNotEmpty) {
        epubCoverUrisByBookKey[key] = imageUrl;
      }
    }
    final Set<String> srtBookKeys = {
      for (final b in allSrtBooks)
        if (b.bookKey.isNotEmpty) b.bookKey,
    };
    final List<MediaItem> epubBooks = srtBookKeys.isEmpty
        ? books
        : books.where((item) {
            final String? key = _parseBookKey(item.mediaIdentifier);
            return key == null || !srtBookKeys.contains(key);
          }).toList();

    final bool hasActiveFilter = ref.read(selectedTagIdsProvider).isNotEmpty;
    final Set<int>? srtFilterSet =
        ref.watch(filteredSrtBookIdsProvider).valueOrNull;
    final List<SrtBook> srtBooks;
    if (srtFilterSet != null) {
      srtBooks = allSrtBooks
          .where((b) => b.id != null && srtFilterSet.contains(b.id))
          .toList();
    } else if (hasActiveFilter) {
      srtBooks = const [];
    } else {
      srtBooks = allSrtBooks;
    }
    // 实验视频 tab 启用时，视频归「视频」tab 独占，书架不再显示视频分区（用户反馈：
    // 书架是书的地方）；开关关闭（无视频 tab）时书架照旧显示，保持向后兼容。
    // 视频现已纳入共享标签系统：筛选激活时按命中的 bookUid 过滤（不再整组隐藏）。
    final Set<String>? videoFilter =
        ref.watch(filteredVideoBookUidsProvider).valueOrNull;
    final List<VideoBookRow> videoBooks = appModel.experimentalVideoEnabled
        ? const <VideoBookRow>[]
        : (videoFilter == null
            ? _videoBooks
            : _videoBooks
                .where((VideoBookRow b) => videoFilter.contains(b.bookUid))
                .toList());
    _visibleEpubBooks = epubBooks;
    _visibleSrtBooks = srtBooks;
    // 多端库联合视图（spec 2026-07-12 §2.1/§2.4/§2.5）：把「远端有、本地无」的书
    // 混排成主网格占位卡。远端目录拉取失败/未配对/无后端（remoteState==null 或
    // failed）→ 占位卡不出现（离线=只剩本地）；「显示远端条目」开关关闭 → 同样不
    // 渲染；标签筛选激活时占位卡不参与（远端书无本地标签），只在无筛选时混排。
    final _RemoteBookState? remoteState = remoteSnapshot?.data;
    final List<RemoteBookInfo> remoteBooks = (remoteState != null &&
            !remoteState.failed &&
            !hasActiveFilter &&
            appModel.prefsRepo.showRemoteEntries)
        ? remoteState.books
        : const <RemoteBookInfo>[];
    // 统一合集：把 SRT + EPUB 混排序列经 groupByCollections 折叠——散书每条单独成
    // group、同合集折叠成一组（组内序 = 合集 sortIndex，与详情页同源），再按当前
    // 排序方式排 group（散书与合集行同层混排）。「最近阅读」量纲 = 最后阅读时间
    // （[_lastReadAtByBookKey]，BUG-777），不再依赖列表下标假名次。
    final List<CollectionOrderingItem<_ShelfBookSlot>> shelfItems =
        <CollectionOrderingItem<_ShelfBookSlot>>[
      for (final SrtBook srt in srtBooks)
        CollectionOrderingItem<_ShelfBookSlot>(
          mediaType: 'srt',
          entryKey: srt.uid,
          importedAt: srt.importedAt,
          payload: _ShelfBookSlot(srt: srt),
        ),
      for (final MediaItem epub in epubBooks)
        CollectionOrderingItem<_ShelfBookSlot>(
          mediaType: 'epub',
          entryKey: _parseBookKey(epub.mediaIdentifier) ?? '',
          importedAt:
              _epubImportedAtByKey[_parseBookKey(epub.mediaIdentifier) ?? ''] ??
                  0,
          payload: _ShelfBookSlot(epub: epub),
        ),
    ];
    // 远端占位书混入（多端库联合视图 §2.3 任务10）：远端书是 host EPUB 库条目，给
    // **真实 mediaType='epub' + entryKey=bookKey**（downloadId），使其能与本地 epub 成员
    // 共键折进合集。importedAt 用 `-1-index`：全为负，稳定排在所有本地条目（正毫秒戳）之后，
    // 组内保持远端目录序（spec §2.1「无本地 importedAt/lastReadAt 时目录序退化」）。
    for (int i = 0; i < remoteBooks.length; i++) {
      shelfItems.add(
        CollectionOrderingItem<_ShelfBookSlot>(
          mediaType: 'epub',
          entryKey: remoteBooks[i].downloadId,
          importedAt: -1 - i,
          payload: _ShelfBookSlot(remote: remoteBooks[i]),
        ),
      );
    }
    // §2.3 任务10：注入远端书的主合集归属（host 下发的 RemoteBookInfo.collection）到折叠
    // 映射，使远端占位卡折进对应本地合集行。远端合集本地无 id——按 (name, type) 对本地合集
    // 表解析（[_resolveLocalCollectionId]），解析不到 = 散卡降级（不硬造合集行）。局部拷贝
    // 页级映射后注入，避免污染跨帧共享的 _primaryCollectionByEntry / _memberSortIndex。
    final Map<String, int> primaryByEntry =
        Map<String, int>.of(_primaryCollectionByEntry);
    final Map<String, int> memberSortIndex =
        Map<String, int>.of(_memberSortIndex);
    for (final RemoteBookInfo book in remoteBooks) {
      final RemoteCollectionMembership? membership = book.collection;
      if (membership == null) continue;
      final int? cid = _resolveLocalCollectionId(
        membership.collectionName,
        membership.collectionType,
      );
      if (cid == null) continue; // 归属解析不到本地合集 → 散卡降级
      final String key = 'epub|${book.downloadId}';
      primaryByEntry[key] = cid;
      memberSortIndex[key] = membership.sortIndex;
    }
    final List<CollectionGroup<_ShelfBookSlot>> shelfGroups =
        groupByCollections<_ShelfBookSlot>(
      items: shelfItems,
      primaryCollectionIdByEntry: primaryByEntry,
      collectionsById: _collectionsById,
      memberSortIndex: memberSortIndex,
    );
    shelfGroups.sort(
      (CollectionGroup<_ShelfBookSlot> a, CollectionGroup<_ShelfBookSlot> b) =>
          compareShelfSortKeys(
        _shelfGroupSortKey(a),
        _shelfGroupSortKey(b),
        _sortMode,
      ),
    );
    // 块2：记录本帧渲染成横排行的合集 id（供全选/反选把可见合集纳入整选集）。
    _visibleCollectionIds = <int>[
      for (final CollectionGroup<_ShelfBookSlot> g in shelfGroups)
        if (g.collection != null) g.collection!.id,
    ];
    _epubCoverUrisByBookKey = epubCoverUrisByBookKey;
    _epubBackedBookKeys = epubBackedBookKeys;
    if (epubBooks.isEmpty &&
        srtBooks.isEmpty &&
        videoBooks.isEmpty &&
        remoteBooks.isEmpty) {
      return hasActiveFilter
          ? Center(
              child: HibikiPlaceholderMessage(
                icon: Icons.filter_list_off,
                message: t.tag_no_books_for_filter,
              ),
            )
          : buildPlaceholder();
    }
    if (hasActiveFilter && epubBooks.isEmpty && videoBooks.isEmpty) {
      return RawScrollbar(
        thumbVisibility: true,
        thickness: 3,
        controller: mediaType.scrollController,
        child: LayoutBuilder(
          builder: (context, constraints) => CustomScrollView(
            controller: mediaType.scrollController,
            physics: desktopAwareScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.gap)),
              // 标签筛选激活时不混排远端占位（远端书无本地标签，不参与筛选）。
              // TODO-902: 不再渲染 srt_books_section 分区头，SRT 卡直接进网格。
              if (srtBooks.isNotEmpty)
                SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _gridExtent(context, constraints),
                    childAspectRatio: kShelfBookCardAspectRatio,
                  ),
                  itemCount: srtBooks.length,
                  itemBuilder: (_, i) => _buildSrtCard(
                    srtBooks[i],
                    epubCoverUri: epubCoverUrisByBookKey[srtBooks[i].bookKey],
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      EdgeInsets.all(tokens.spacing.card + tokens.spacing.gap),
                  child: Text(
                    t.tag_no_books_for_filter,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return RawScrollbar(
      thumbVisibility: true,
      thickness: 3,
      controller: mediaType.scrollController,
      child: LayoutBuilder(
        builder: (context, constraints) => CustomScrollView(
          controller: mediaType.scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.gap)),
            // UI v2：书架顶部「继续阅读 hero + 书库概览」条（对齐视频页，用户
            // 拍板「书架也要有」）。空库隐藏；统计按未过滤全量描述整库。
            if (epubBooks.isNotEmpty || srtBooks.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildShelfOverviewSection(epubBooks, srtBooks),
              ),
            // TODO-902: 书架不再按类型分区（删 srt_books_section / section_epub
            // 两个分区头），SRT 有声书卡与 EPUB 卡混排进同一网格（SRT 在前、EPUB
            // 在后，沿用各自现有顺序，卡片本身的类型标识保留）。视频仍是独立分区。
            // 合集 group 渲染成全宽横排行（CollectionShelfRow）集中在前，
            // 散书合成单一 SliverGrid 在后（去碎片方案 A+顶部，已拍板）。多端库联合
            // 视图（spec §2.1）：远端占位书已作为散卡混入 shelfGroups（撤独立远端分区），
            // shelfGroups 非空即渲染（含仅远端占位、无任何本地书的情形）。
            if (shelfGroups.isNotEmpty)
              ..._buildShelfGroupSlivers(
                shelfGroups,
                epubCoverUrisByBookKey,
                constraints,
              ),
            if (videoBooks.isNotEmpty) ...[
              SliverToBoxAdapter(
                  child: _buildSectionHeader(t.shelf_video_section)),
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _gridExtent(context, constraints),
                  // 视频卡保留视频比例，不随 TODO-786 收窄（与 _buildVideoCard 一致）。
                  childAspectRatio: kShelfVideoCardAspectRatio,
                ),
                itemCount: videoBooks.length,
                itemBuilder: (_, i) => _buildVideoCard(videoBooks[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 主网格 sliver 组装：**分区**（去碎片 spec 2026-07-12，已拍板方案 A+顶部）
  /// ——合集横排行集中渲染在前（每个合集独占一行、行内横移看相邻卷/集，区内
  /// 保持排序模式的组间序），散书合成**单一** [SliverGrid] 在后。旧保序交错
  /// 布局每个合集行都把网格切段产生残行（一两本书占一行，用户实报）；分区后
  /// 残行恒 1 个（网格末行）。
  List<Widget> _buildShelfGroupSlivers(
    List<CollectionGroup<_ShelfBookSlot>> groups,
    Map<String, String> epubCoverUrisByBookKey,
    BoxConstraints constraints,
  ) {
    // UI v2：散书网格与合集横排行统一卡宽（用户实报合集卡大一截）——以网格列宽
    // 断点为目标宽算响应式列数，两处共用同一实际卡宽（书卡自带内边距，网格零间距）。
    final ({int columns, double cardWidth}) cardLayout = unifiedShelfCardLayout(
      availableWidth: constraints.maxWidth,
      targetWidth: _gridExtent(context, constraints),
      spacing: 0,
    );
    final List<Widget> slivers = <Widget>[];
    final List<CollectionGroup<_ShelfBookSlot>> loose =
        <CollectionGroup<_ShelfBookSlot>>[];
    for (final CollectionGroup<_ShelfBookSlot> group in groups) {
      if (group.collection == null) {
        loose.add(group);
      } else {
        slivers.add(
          SliverToBoxAdapter(
            child: _buildShelfCollectionRow(
              group,
              epubCoverUrisByBookKey,
              cardLayout,
            ),
          ),
        );
      }
    }
    if (loose.isNotEmpty) {
      slivers.add(
        SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cardLayout.columns,
            childAspectRatio: kShelfBookCardAspectRatio,
          ),
          itemCount: loose.length,
          itemBuilder: (_, i) => _buildShelfGroupCard(
            loose[i],
            epubCoverUrisByBookKey,
          ),
        ),
      );
    }
    return slivers;
  }

  /// 一个书籍合集的全宽横排行：头（合集名+数量+查看全部→详情页，focusId 沿用
  /// `reader-shelf-collection-<id>` 保持标签栏 down-anchor 语义）+ 横向成员卡。
  /// 成员卡复用散书渲染（SRT 卡 / EPUB 卡，点击即开书）；卡宽与网格列宽断点同源。
  Widget _buildShelfCollectionRow(
    CollectionGroup<_ShelfBookSlot> group,
    Map<String, String> epubCoverUrisByBookKey,
    ({int columns, double cardWidth}) cardLayout,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final MediaCollectionRow collection = group.collection!;
    // 与散书网格 cell 同宽（unifiedShelfCardLayout）；书卡槽比 = 宽/高
    // （kShelfBookCardAspectRatio=160/260）→ 行高按同比换算，行内卡与网格卡同形。
    final double itemWidth = cardLayout.cardWidth;
    final double rowHeight = itemWidth / kShelfBookCardAspectRatio;
    // #5：行头计数只数**本地成员**（远端占位不入 n），与合集详情页口径一致（详情页只显示
    // 本地成员）。当前书侧合集成员本就全是本地（远端占位卡不进合集，见 _buildShelfMemberCard），
    // 此过滤是防御性对齐口径；行体（itemCount）仍渲染 group.items 全部。
    final int localCount =
        group.items.where((it) => it.payload.remote == null).length;
    return Padding(
      // 水平不加 padding：书卡自带 12px 内边距，与网格散卡左缘逐像素对齐。
      padding: EdgeInsets.symmetric(
        vertical: tokens.spacing.gap / 2,
      ),
      child: CollectionShelfRow(
        key: ValueKey<String>('reader_shelf_collection_row_${collection.id}'),
        title: collection.name,
        countLabel: t.series_item_count(n: localCount),
        itemCount: group.items.length,
        itemWidth: itemWidth,
        rowHeight: rowHeight,
        // 书卡自带 12px 内边距 → 行内间距归零，与散书网格视觉间距一致。
        itemGap: 0,
        headerFocusId:
            HibikiFocusId('reader-shelf-collection-${collection.id}'),
        onOpenDetail: () => _openCollectionDetail(collection),
        collapsed:
            appModel.prefsRepo.collapsedCollectionIds.contains(collection.id),
        onToggleCollapsed: () => _toggleCollectionCollapsed(collection.id),
        // 块2：多选态行头挂整选勾选框（选=选中整个合集）；成员卡多选态不可单独勾。
        selectionCheckbox: _selectionMode
            ? _buildSelectionCheck(
                _selectedCollectionIds.contains(collection.id))
            : null,
        onToggleSelected: _selectionMode
            ? () => _toggleCollectionSelection(collection.id)
            : null,
        itemBuilder: (BuildContext _, int i) => _buildShelfMemberCard(
          group.items[i].payload,
          epubCoverUrisByBookKey,
          selectable: false,
        ),
      ),
    );
  }

  /// 横排行成员卡：SRT / EPUB 复用散书卡渲染（交互/焦点自带）。
  ///
  /// [selectable]（默认 true）= 该卡在多选态可单独勾选。块2：合集行成员卡传 false——
  /// 多选态不画勾选框、不可单独勾（整合集由行头勾选框选中），点击照常开书。
  Widget _buildShelfMemberCard(
    _ShelfBookSlot slot,
    Map<String, String> epubCoverUrisByBookKey, {
    bool selectable = true,
  }) {
    // 远端占位卡不进合集（本批无合集归属），此分支纯防御避免 epub! 空断言。
    final RemoteBookInfo? remote = slot.remote;
    if (remote != null) return _buildRemoteBookCard(remote);
    final SrtBook? srt = slot.srt;
    if (srt != null) {
      return _buildSrtCard(srt,
          epubCoverUri: epubCoverUrisByBookKey[srt.bookKey],
          selectable: selectable);
    }
    return _buildEpubBookCard(slot.epub!, selectable: selectable);
  }

  /// 统一合集 Phase 4：渲染一个书架 group——散书（collection==null，单成员）回退到原有
  /// 卡片渲染（与历史逐像素一致）；合集 group 渲染 [SeriesShelfCard]（首成员封面 + 角标）。
  /// UI v2 Phase C 后主网格只喂散 group（合集走 [_buildShelfCollectionRow] 横排行）；
  /// 合集分支保留给零星旧调用防御。
  Widget _buildShelfGroupCard(
    CollectionGroup<_ShelfBookSlot> group,
    Map<String, String> epubCoverUrisByBookKey,
  ) {
    final MediaCollectionRow? collection = group.collection;
    if (collection == null) {
      final _ShelfBookSlot slot = group.coverItem.payload;
      // 多端库联合视图（spec §2.1）：远端占位散卡走远端书卡渲染（云角标 + 远端封面
      // + 下载按钮，点击复用下载→入库链）。远端书永无合集归属，只走此散卡路径。
      final RemoteBookInfo? remote = slot.remote;
      if (remote != null) {
        return _buildRemoteBookCard(remote);
      }
      final SrtBook? srt = slot.srt;
      if (srt != null) {
        return _buildSrtCard(
          srt,
          epubCoverUri: epubCoverUrisByBookKey[srt.bookKey],
        );
      }
      return buildMediaItem(slot.epub!);
    }
    // 统一合集 Phase 4：前 4 张成员封面喂 SeriesShelfCard 做「露出后面几本书」的堆叠视觉。
    final List<Widget> covers = <Widget>[
      for (final CollectionOrderingItem<_ShelfBookSlot> it
          in group.items.take(4))
        _slotCover(it.payload, epubCoverUrisByBookKey),
    ];
    return SeriesShelfCard(
      name: collection.name,
      itemCount: group.items.length,
      slotAspectRatio: kShelfBookCardAspectRatio,
      // Gamepad/keyboard focus id：与散书卡同 'reader-shelf-<kind>-<id>' 方案，
      // 折叠合集可被 D-pad 到达。
      focusId: HibikiFocusId('reader-shelf-collection-${collection.id}'),
      covers: covers,
      onTap: () => _openCollectionDetail(collection),
    );
  }

  /// 取一个排序槽的封面图（仅封面，无交互），供系列折叠卡片复用。
  Widget _slotCover(
    _ShelfBookSlot slot,
    Map<String, String> epubCoverUrisByBookKey,
  ) {
    // 远端占位卡不进合集折叠堆叠封面（本批无合集归属），此分支纯防御。
    final RemoteBookInfo? remote = slot.remote;
    if (remote != null) return _buildRemoteBookCover(remote);
    final SrtBook? srt = slot.srt;
    if (srt != null) {
      return _buildSrtCover(
        srt,
        epubCoverUri: epubCoverUrisByBookKey[srt.bookKey],
      );
    }
    final MediaItem item = slot.epub!;
    return FadeInImage(
      imageErrorBuilder: (_, __, ___) =>
          _coverPlaceholderIcon(Icons.menu_book_outlined),
      placeholder: MemoryImage(kTransparentImage),
      image: mediaSource.getDisplayThumbnailFromMediaItem(
        appModel: appModel,
        item: item,
      ),
      alignment: Alignment.topCenter,
      fit: _bookCardCoverFit,
    );
  }

  /// 统一合集 Phase 4：打开合集详情页（成员网格 / 重命名 / 删除 / 移出）。写库后重载。
  void _openCollectionDetail(MediaCollectionRow collection) {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        builder: (_) => MediaCollectionGridDetailPage(
          database: appModel.database,
          collection: collection,
          memberCardBuilder: _buildCollectionMemberCard,
          onOpenMember: _openCollectionMember,
          onChanged: () {
            _shelfMapsFuture = _loadShelfMaps();
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  /// 系列详情页按成员行渲染卡片：epub → 经书架 provider 找 MediaItem；srt → 经 uid
  /// 找 SrtBook。找不到（条目已删 / 远端离线）返回 null，详情页跳过该成员。
  /// 合集详情页成员卡渲染：按 (mediaType, entryKey) 找当前可见的 SRT / EPUB 书渲染，
  /// 找不到（孤儿 / 被过滤）返回 null（详情页跳过）。
  ///
  /// [onRemoveFromCollection]（详情页注入 `() => _removeMember(row)`）非空时把「移出合集」
  /// 接进该成员卡长按 / 右键对话框（键盘/手柄用户聚焦长按 A 走此对话框而非网格指针菜单，
  /// 不注入就没有移出项）。
  Widget? _buildCollectionMemberCard(String mediaType, String entryKey,
      {VoidCallback? onRemoveFromCollection}) {
    if (mediaType == 'srt') {
      for (final SrtBook book in _visibleSrtBooks) {
        if (book.uid == entryKey) {
          return _buildSrtCard(
            book,
            epubCoverUri: _epubCoverUrisByBookKey[book.bookKey],
            removeFromCollection: onRemoveFromCollection,
          );
        }
      }
      return null;
    }
    if (mediaType == 'epub') {
      for (final MediaItem item in _visibleEpubBooks) {
        if (_parseBookKey(item.mediaIdentifier) == entryKey) {
          return _buildEpubBookCard(
            item,
            removeFromCollection: onRemoveFromCollection,
          );
        }
      }
      return null;
    }
    return null;
  }

  /// 合集详情页「打开成员」（点卡片 / 菜单「打开」）：卡片自身手势被 IgnorePointer
  /// 屏蔽（见 [MediaCollectionGridDetailPage]），故打开统一经此回调走与书架卡片
  /// onTap 相同的路径——epub 经 openMedia，srt 经 _openSrtBook。
  void _openCollectionMember(String mediaType, String entryKey) {
    if (mediaType == 'srt') {
      for (final SrtBook book in _visibleSrtBooks) {
        if (book.uid == entryKey) {
          unawaited(_openSrtBook(book));
          return;
        }
      }
      return;
    }
    if (mediaType == 'epub') {
      for (final MediaItem item in _visibleEpubBooks) {
        if (_parseBookKey(item.mediaIdentifier) == entryKey) {
          final MediaSource source = item.getMediaSource(appModel: appModel);
          unawaited(
              appModel.openMedia(ref: ref, mediaSource: source, item: item));
          return;
        }
      }
    }
  }

  Widget _buildSectionHeader(String label) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.gap,
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.gap / 4,
      ),
      child: Text(
        label,
        // Shared MD3 section label (labelLarge / primary / w600) — same role as
        // the settings detail section headers, replacing the ad-hoc styling.
        style: tokens.type.sectionLabel,
      ),
    );
  }

  Future<bool> _confirmMediaDelete({
    required String title,
    required String message,
  }) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: title,
        message: message,
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    return confirmed == true && mounted;
  }

  @override
  Widget buildPlaceholder() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HibikiPlaceholderMessage(
            icon: mediaSource.icon,
            message: t.ttu_no_books_added,
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          FilledButton.icon(
            icon: const Icon(Icons.library_add_outlined, size: 18),
            label: Text(t.srt_import),
            onPressed: () async {
              final bool? imported = await showAppDialog<bool>(
                context: context,
                builder: (_) => BookImportDialog(
                  repo: SrtBookRepository(appModel.database),
                  audiobookRepo: AudiobookRepository(appModel.database),
                  db: appModel.database,
                ),
              );
              if (imported == true) {
                ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
                ref.invalidate(srtBooksProvider);
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget buildMediaItemContent(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    // Audiobook info is keyed by the book's bookKey (the Audiobooks table key),
    // NOT the MediaItem.uniqueKey (which is the source-prefixed identifier).
    final info = _getAudiobookInfo(bookKey ?? '');
    final bool hasAudiobook = info.hasAudiobook;
    final HealthKind healthKind = info.healthKind;

    final tagWidget = bookKey != null ? _buildTagLabels(bookKey) : null;

    return _bookCardLayout(
      title: mediaSource.getDisplayTitleFromMediaItem(item),
      cover: FadeInImage(
        imageErrorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.menu_book_outlined),
        placeholder: MemoryImage(kTransparentImage),
        image: mediaSource.getDisplayThumbnailFromMediaItem(
          appModel: appModel,
          item: item,
        ),
        alignment: Alignment.topCenter,
        fit: _bookCardCoverFit,
      ),
      tagLabels: tagWidget,
      coverBadge: hasAudiobook
          ? _audiobookBadge(healthKind)
          : _cardBadge(
              icon: Icons.menu_book_outlined,
              background: theme.colorScheme.surfaceContainerHighest,
              foreground: theme.colorScheme.onSurfaceVariant,
            ),
      metadata: _progressBar(item),
    );
  }

  @override
  Widget buildMediaItem(MediaItem item) =>
      _buildEpubBookCard(item, selectable: true);

  /// EPUB 书卡渲染。[selectable]（默认经 [buildMediaItem] 传 true）= 多选态可单独勾选；
  /// 块2：合集行成员卡传 false（selectionKey 置空 → 不画勾、不可单独勾）。
  /// [removeFromCollection] 非空（合集详情页成员卡）时给长按 / 右键对话框补一条
  /// 「移出合集」动作，让键盘/手柄用户（聚焦长按 A 弹此对话框，不经网格指针菜单）也能移出。
  Widget _buildEpubBookCard(MediaItem item,
      {bool selectable = true, VoidCallback? removeFromCollection}) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    final Widget card = _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('book_entry_${item.mediaIdentifier}'),
      focusId: HibikiFocusId('reader-shelf-book-${item.mediaIdentifier}'),
      selectionKey: selectable ? item.mediaIdentifier : null,
      dragBookId: bookKey,
      onTagDropped:
          bookKey == null ? null : (tag) => _addTagToBook(bookKey, tag),
      onTap: () async {
        final MediaSource source = item.getMediaSource(appModel: appModel);
        await appModel.openMedia(
          ref: ref,
          mediaSource: source,
          item: item,
        );
      },
      onLongPress: () async {
        await showAppDialog(
          context: context,
          builder: (BuildContext dialogCtx) => MediaItemDialogPage(
            item: item,
            isHistory: isHistory,
            showLaunchAction: false,
            extraActions: removeFromCollection == null
                ? extraActions
                : (MediaItem it) => <DialogAction>[
                      ...extraActions(it),
                      DialogListAction(
                        label: t.collection_remove_member,
                        icon: Icons.remove_circle_outline,
                        onPressed: () {
                          Navigator.pop(dialogCtx);
                          removeFromCollection();
                        },
                      ),
                    ],
          ),
        );
        if (isHistory) {
          setState(() {});
        }
      },
      child: buildMediaItemContent(item),
    );
    // 仅 EPUB 书卡作为字幕/音频拖放目标；SRT 卡/视频卡不在 books 表面范围内。
    if (bookKey == null) return card;
    return CardDropZone<String>(meta: bookKey, child: card);
  }

  @override
  List<DialogAction> extraActions(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    if (bookKey == null) return const [];
    return <DialogAction>[
      DialogDangerAction(
        label: t.dialog_delete,
        onPressed: () => _confirmDeleteEpub(item, bookKey),
      ),
      DialogQuickAction(
        label: t.view_illustrations,
        icon: Icons.image_outlined,
        onPressed: () => _openIllustrations(item, bookKey),
      ),
      DialogQuickAction(
        label: t.audiobook_import,
        icon: Icons.headphones_outlined,
        onPressed: () => _openAudiobookImport(item, bookKey),
      ),
      DialogListAction(
        label: t.profile_book_profile,
        icon: Icons.account_circle_outlined,
        onPressed: () => _openBookProfilePicker(item, bookKey),
      ),
      DialogListAction(
        label: t.book_css_editor_edit_css,
        icon: Icons.code_outlined,
        onPressed: () => _openCssEditor(bookKey),
      ),
      // TODO-291 阶段2：书架长按「悬浮字幕」= 启动该书的后台听书会话（无正在播则用该书
      // 启动 + 拉起悬浮窗），不再只翻 bool。该书已是活动会话则改为「停止后台听书」。
      if (Platform.isAndroid || Platform.isWindows)
        DialogListAction(
          label: _isBackgroundListeningBook(bookKey)
              ? '${t.floating_lyric_toggle_action} ✓'
              : t.floating_lyric_toggle_action,
          icon: Icons.subtitles_outlined,
          onPressed: () => _toggleFloatingLyricFromShelf(bookKey),
        ),
    ];
  }

  String? _parseBookKey(String mediaIdentifier) =>
      ReaderHibikiSource.parseBookKey(mediaIdentifier);

  // ── 拖拽导入（books 表面） ──────────────────────────────────────────────────
}

/// 书架混排网格的单个排序槽（SRT / EPUB / 远端占位三类卡片到一个有序列表）。
/// [srt]/[epub]/[remote] 恰有一个非空。「最近阅读」量纲不在槽里——由页面级
/// `_lastReadAtByBookKey`（reader_positions.updatedAt）按 bookKey 查（BUG-777）。
///
/// [remote] = 多端库联合视图（spec 2026-07-12 §2.1）的「远端有、本地无」占位卡：
/// 无本地 importedAt/lastReadAt，排序退化到目录序（注入时以 `-1-index` 编码进
/// CollectionOrderingItem.importedAt，稳定排在本地条目之后、组内保持目录序）。
class _ShelfBookSlot {
  const _ShelfBookSlot({
    this.srt,
    this.epub,
    this.remote,
  });

  final SrtBook? srt;
  final MediaItem? epub;
  final RemoteBookInfo? remote;
}
