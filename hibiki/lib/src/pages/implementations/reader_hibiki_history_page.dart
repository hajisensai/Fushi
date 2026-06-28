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
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/media/video/video_subtitle_attach.dart';
import 'package:hibiki/src/pages/implementations/book_drag_target.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:hibiki/src/pages/implementations/series_detail_page.dart';
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
import 'package:hibiki/src/sync/remote_cover_headers.dart';
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
  List<MediaItem> _visibleEpubBooks = const [];
  List<SrtBook> _visibleSrtBooks = const [];
  Map<String, String> _epubCoverUrisByBookKey = const {};

  // 视频书单独分区：无 Riverpod provider，按需载入 state 并在导入后刷新。
  List<VideoBookRow> _videoBooks = const [];
  Future<List<VideoBookRow>>? _videoBooksFuture;
  Future<_RemoteBookState?>? _remoteBooksFuture;

  /// TODO-616 B2：自定义排序映射 `"mediaType|entryKey" → sortOrder`，开页/落盘后
  /// 加载一次，渲染时把 SRT+EPUB 混排网格按它稳定排序（无行的条目退化原序）。
  Future<Map<String, int>>? _shelfOrderFuture;
  Map<String, int> _shelfOrder = const <String, int>{};

  /// TODO-616 A2：分组渲染所需的全部 ShelfEntries 原始行 + 系列字典，与
  /// [_shelfOrder] 同一次 [_loadShelfOrder] 预取（避免二次查库）。
  List<ShelfEntryRow> _allShelfEntries = const <ShelfEntryRow>[];
  Map<int, SeriesRow> _seriesById = const <int, SeriesRow>{};
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
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  void _toggleSelection(String key) {
    setState(() {
      if (!_selectedKeys.remove(key)) {
        _selectedKeys.add(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<MediaItem>> books =
        ref.watch(hibikiBooksProvider(appModel.targetLanguage));
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
                      _shelfOrderFuture ??= _loadShelfOrder();
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
                                FutureBuilder<Map<String, int>>(
                              future: _shelfOrderFuture,
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
      onTagsChanged: () => ref.invalidate(bookTagMapProvider),
    );
  }

  Widget _buildPageHeader() {
    return HibikiPageHeader(
      title: t.books,
      actions: <Widget>[
        mediaSource.buildBookImportButton(
          context: context,
          ref: ref,
          appModel: appModel,
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
        _headerAction(
          tooltip: t.shelf_edit_order,
          icon: Icons.swap_vert,
          onTap: _openShelfSort,
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

  /// TODO-616 B2：打开书架「编辑排序」独立重排页。把当前可见的 SRT + EPUB 卡片
  /// （与网格同序：SRT 在前、EPUB 在后）构造成可重排条目 push 进 [ShelfReorderPage]，
  /// 退出时按最终顺序批量回写 ShelfEntries.sortOrder（下标即新 sortOrder）。视频在
  /// 书架是独立分区且归视频 tab 管，不纳入本页（在视频库页单独排序）。
  Future<void> _openShelfSort() async {
    if (_selectionMode) _exitSelectionMode();
    final List<ShelfReorderItem> items = <ShelfReorderItem>[];
    for (final SrtBook book in _visibleSrtBooks) {
      items.add(ShelfReorderItem(
        mediaType: 'srt',
        entryKey: book.uid,
        card: _buildSrtCard(
          book,
          epubCoverUri: _epubCoverUrisByBookKey[book.bookKey],
        ),
      ));
    }
    for (final MediaItem item in _visibleEpubBooks) {
      final String? bookKey = _parseBookKey(item.mediaIdentifier);
      if (bookKey == null) continue;
      items.add(ShelfReorderItem(
        mediaType: 'epub',
        entryKey: bookKey,
        card: buildMediaItem(item),
      ));
    }
    if (items.length < 2) {
      HibikiToast.show(msg: t.shelf_sort_saved);
      return;
    }
    await Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        builder: (_) => ShelfReorderPage(
          title: t.shelf_edit_order,
          initialItems: items,
          cellExtent: 180,
          childAspectRatio: kShelfBookCardAspectRatio,
          feedbackBorderRadius: const BorderRadius.all(Radius.circular(12)),
          onPersist: _persistShelfOrder,
        ),
      ),
    );
  }

  /// 把重排页给回的最终顺序按下标批量回写 ShelfEntries.sortOrder（单事务）。
  Future<void> _persistShelfOrder(List<ShelfReorderItem> ordered) async {
    final List<({String mediaType, String entryKey, int sortOrder})> orders =
        <({String mediaType, String entryKey, int sortOrder})>[
      for (int i = 0; i < ordered.length; i++)
        (
          mediaType: ordered[i].mediaType,
          entryKey: ordered[i].entryKey,
          sortOrder: i,
        ),
    ];
    await appModel.database.batchUpsertShelfOrder(orders);
    _shelfOrderFuture = _loadShelfOrder();
    if (mounted) setState(() {});
  }

  /// 一次性预取全部 ShelfEntries，组装成 `"mediaType|entryKey" → sortOrder` 映射。
  Future<Map<String, int>> _loadShelfOrder() async {
    final List<ShelfEntryRow> rows =
        await appModel.database.getAllShelfEntries();
    final List<SeriesRow> series = await appModel.database.getAllSeries();
    final Map<String, int> map = <String, int>{
      for (final ShelfEntryRow r in rows)
        '${r.mediaType}|${r.entryKey}': r.sortOrder,
    };
    _shelfOrder = map;
    _allShelfEntries = rows;
    _seriesById = <int, SeriesRow>{for (final SeriesRow s in series) s.id: s};
    return map;
  }

  /// 某条目的自定义排序权重（无行退化为 0；与 groupAndSortShelfEntries 同语义）。
  int _orderOf(String mediaType, String entryKey) =>
      _shelfOrder['$mediaType|$entryKey'] ?? 0;

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

  Widget _buildBodyWithSrtBooks(
    List<MediaItem> books,
    List<SrtBook> allSrtBooks,
    AsyncSnapshot<_RemoteBookState?>? remoteSnapshot,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Map<String, String> epubCoverUrisByBookKey = {};
    for (final MediaItem item in books) {
      final String? key = _parseBookKey(item.mediaIdentifier);
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
    // TODO-616 A2：把 SRT + EPUB 混排序列经 groupAndSortShelfEntries 分组——散书每条
    // 单独成 group、同 seriesId 折叠成系列卡片，散书与系列卡片同层混排。零系列时每条
    // 散书单独成 group，顺序与历史 mergedBooks（sortOrder asc, 原序 tie-break）一致。
    final List<ShelfOrderingItem<_ShelfBookSlot>> shelfItems =
        <ShelfOrderingItem<_ShelfBookSlot>>[
      for (int i = 0; i < srtBooks.length; i++)
        ShelfOrderingItem<_ShelfBookSlot>(
          mediaType: 'srt',
          entryKey: srtBooks[i].uid,
          importedAt: -i,
          payload: _ShelfBookSlot(
            seq: i,
            order: _orderOf('srt', srtBooks[i].uid),
            srt: srtBooks[i],
          ),
        ),
      for (int i = 0; i < epubBooks.length; i++)
        ShelfOrderingItem<_ShelfBookSlot>(
          mediaType: 'epub',
          entryKey: _parseBookKey(epubBooks[i].mediaIdentifier) ?? '',
          importedAt: -(srtBooks.length + i),
          payload: _ShelfBookSlot(
            seq: srtBooks.length + i,
            order: _orderOf(
                'epub', _parseBookKey(epubBooks[i].mediaIdentifier) ?? ''),
            epub: epubBooks[i],
          ),
        ),
    ];
    final List<ShelfGroup<_ShelfBookSlot>> shelfGroups =
        groupAndSortShelfEntries<_ShelfBookSlot>(
      items: shelfItems,
      shelfEntries: _allShelfEntries,
      seriesById: _seriesById,
    );
    _epubCoverUrisByBookKey = epubCoverUrisByBookKey;
    final _RemoteBookState? remoteState = remoteSnapshot?.data;
    final bool showRemoteBooks = remoteState != null &&
        (remoteState.failed || remoteState.books.isNotEmpty);
    if (epubBooks.isEmpty &&
        srtBooks.isEmpty &&
        videoBooks.isEmpty &&
        !showRemoteBooks) {
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
              if (showRemoteBooks)
                SliverToBoxAdapter(
                  child: _buildRemoteBookSection(remoteState, constraints),
                ),
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
            if (showRemoteBooks)
              SliverToBoxAdapter(
                child: _buildRemoteBookSection(remoteState, constraints),
              ),
            // TODO-902: 书架不再按类型分区（删 srt_books_section / section_epub
            // 两个分区头），SRT 有声书卡与 EPUB 卡混排进同一网格（SRT 在前、EPUB
            // 在后，沿用各自现有顺序，卡片本身的类型标识保留）。视频仍是独立分区。
            if (srtBooks.isNotEmpty || epubBooks.isNotEmpty)
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _gridExtent(context, constraints),
                  childAspectRatio: kShelfBookCardAspectRatio,
                ),
                itemCount: shelfGroups.length,
                itemBuilder: (_, i) => _buildShelfGroupCard(
                  shelfGroups[i],
                  epubCoverUrisByBookKey,
                ),
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

  /// TODO-616 A2：渲染一个书架 group——散书（seriesId==null，单成员）回退到原有卡片
  /// 渲染（与历史逐像素一致）；系列 group 渲染 [SeriesShelfCard]（首卷封面 + 角标）。
  Widget _buildShelfGroupCard(
    ShelfGroup<_ShelfBookSlot> group,
    Map<String, String> epubCoverUrisByBookKey,
  ) {
    if (group.seriesId == null) {
      final _ShelfBookSlot slot = group.coverItem.payload;
      final SrtBook? srt = slot.srt;
      if (srt != null) {
        return _buildSrtCard(
          srt,
          epubCoverUri: epubCoverUrisByBookKey[srt.bookKey],
        );
      }
      return buildMediaItem(slot.epub!);
    }
    final int seriesId = group.seriesId!;
    final SeriesRow? series = _seriesById[seriesId];
    final _ShelfBookSlot coverSlot = group.coverItem.payload;
    return SeriesShelfCard(
      name: series?.name ?? t.series,
      itemCount: group.items.length,
      slotAspectRatio: kShelfBookCardAspectRatio,
      cover: _slotCover(coverSlot, epubCoverUrisByBookKey),
      onTap: () => _openSeriesDetail(seriesId, series?.name ?? t.series),
    );
  }

  /// 取一个排序槽的封面图（仅封面，无交互），供系列折叠卡片复用。
  Widget _slotCover(
    _ShelfBookSlot slot,
    Map<String, String> epubCoverUrisByBookKey,
  ) {
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

  /// 打开系列详情页（成员网格 / 重命名 / 删除 / 移出 / 重排）。写库后重载分组渲染。
  void _openSeriesDetail(int seriesId, String name) {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        builder: (_) => SeriesDetailPage(
          database: appModel.database,
          seriesId: seriesId,
          initialName: name,
          memberCardBuilder: _buildSeriesMemberCard,
          onChanged: () {
            _shelfOrderFuture = _loadShelfOrder();
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  /// 系列详情页按成员行渲染卡片：epub → 经书架 provider 找 MediaItem；srt → 经 uid
  /// 找 SrtBook。找不到（条目已删 / 远端离线）返回 null，详情页跳过该成员。
  Widget? _buildSeriesMemberCard(ShelfEntryRow row) {
    if (row.mediaType == 'srt') {
      for (final SrtBook book in _visibleSrtBooks) {
        if (book.uid == row.entryKey) {
          return _buildSrtCard(
            book,
            epubCoverUri: _epubCoverUrisByBookKey[book.bookKey],
          );
        }
      }
      return null;
    }
    if (row.mediaType == 'epub') {
      for (final MediaItem item in _visibleEpubBooks) {
        if (_parseBookKey(item.mediaIdentifier) == row.entryKey) {
          return buildMediaItem(item);
        }
      }
      return null;
    }
    return null;
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
  Widget buildMediaItem(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    final Widget card = _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('book_entry_${item.mediaIdentifier}'),
      focusId: HibikiFocusId('reader-shelf-book-${item.mediaIdentifier}'),
      selectionKey: item.mediaIdentifier,
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
          builder: (_) => MediaItemDialogPage(
            item: item,
            isHistory: isHistory,
            showLaunchAction: false,
            extraActions: extraActions,
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

/// TODO-616 B2：书架 SRT+EPUB 混排网格的单个排序槽（合并两类卡片到一个有序列表）。
/// [srt]/[epub] 恰有一个非空。[order] = ShelfEntries.sortOrder（无行退化 0），
/// [seq] = 原序列下标（SRT 在前 EPUB 在后），作零自定义排序时的稳定 tie-break。
class _ShelfBookSlot {
  const _ShelfBookSlot({
    required this.seq,
    required this.order,
    this.srt,
    this.epub,
  });

  final int seq;
  final int order;
  final SrtBook? srt;
  final MediaItem? epub;
}
