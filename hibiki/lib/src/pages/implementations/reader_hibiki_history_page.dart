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
import 'package:hibiki/src/pages/implementations/book_drag_target.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_download_progress_badge.dart';
import 'package:hibiki/src/sync/remote_cover_headers.dart';
import 'package:hibiki/src/sync/remote_book_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/utils.dart';

/// 自适应标签列在给定可用高度下能放几个 chip slot。
///
/// 根因守卫：当 [maxHeight] 无界（== infinity，例如标签覆盖层用
/// `Positioned(top, left)`（无 bottom/height）落进 `Stack(fit: StackFit.expand)`
/// 时拿到 unbounded 约束），旧实现 `(maxHeight * 0.55 / chipHeight).floor()` 会在
/// Infinity 上抛 `UnsupportedError: Infinity or NaN toInt` —— 表现为书本打 tag 后
/// 封面卡片渲染异常（debug 红框/错误占位）。无界时返回全部标签数，渲染全部、由父
/// 级自然裁剪，而不是吞异常或硬编码 slot。
@visibleForTesting
int adaptiveTagSlots({
  required double maxHeight,
  required int tagCount,
  double chipHeight = 22.0,
}) {
  if (tagCount <= 0) return 0;
  if (!maxHeight.isFinite) return tagCount;
  final double usable = maxHeight * 0.55;
  return (usable / chipHeight).floor().clamp(1, tagCount);
}

/// 书架书卡封面右上角类型徽章（有声书 / 普通书）的方框边长（逻辑像素）。
///
/// 历史：早期徽章夹在封面下方的 footer 文字行里、紧贴小号书名，读作一个克制的小角标。
/// TODO-355 把徽章移到封面图上后，旧布局用 `SizedBox.square(gap*5=40) + BoxFit.scaleDown`
/// 包住内在 22px（HibikiBadge：icon 14 + padding gap 8）的徽章——`scaleDown` 永不放大也
/// 永不缩小已小于 40px 的徽章，于是徽章仍按 22px 满尺寸压在封面图上，比原来「大了一圈」。
/// 这里把方框收到设计 token 基准 `gap * 2 = 16` 并改用 `BoxFit.contain`，让 22px 徽章等比
/// 缩到 16px，恢复书架原来那种约「半个」大小（用户记忆里的 0.5 显示）的小角标观感。
/// 用顶层常量 + 测试可见，便于 widget 守卫断言渲染尺寸，防止再次漂移。
const double kShelfCoverBadgeDimension = 8.0 * 2;

class ReaderHibikiHistoryPage extends HistoryReaderPage {
  const ReaderHibikiHistoryPage({
    this.remoteBookClientLoader,
    this.remoteBookDownloadDestination,
    this.remoteBookImporter,
    super.key,
  });

  final Future<RemoteBookClient?> Function()? remoteBookClientLoader;
  final Future<File> Function(RemoteBookInfo book)?
      remoteBookDownloadDestination;
  final Future<void> Function(File file)? remoteBookImporter;

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

  // 视频书单独分区：无 Riverpod provider，按需载入 state 并在导入后刷新。
  List<VideoBookRow> _videoBooks = const [];
  Future<List<VideoBookRow>>? _videoBooksFuture;
  Future<_RemoteBookState?>? _remoteBooksFuture;
  RemoteBookClient? _remoteBookClient;

  /// 正在下载中的远端书（key = book.title）。值为进度分数 0..1；收到首个
  /// onProgress 前为 null（不确定进度）。下载期间用它在卡片上替换下载按钮为进度
  /// 指示（#3：远端下载全程有进行中反馈，不再 await 完才弹一次提示）。
  final Map<String, double?> _downloadingBooks = <String, double?>{};

  VideoBookRepository get _videoRepo => VideoBookRepository(appModel.database);

  Future<List<VideoBookRow>> _loadVideoBooks() async {
    final List<VideoBookRow> rows = await _videoRepo.listAll();
    _videoBooks = rows;
    return rows;
  }

  void _refreshVideoBooks() {
    setState(() {
      _videoBooksFuture = _loadVideoBooks();
    });
  }

  Future<RemoteBookClient?> _resolveRemoteBookClient() async {
    final Future<RemoteBookClient?> Function()? injected =
        _pageWidget.remoteBookClientLoader;
    if (injected != null) return injected();

    final SyncRepository syncRepo = SyncRepository(appModel.database);
    if (await syncRepo.getBackendType() != SyncBackendType.hibikiServer) {
      return null;
    }
    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.instance;
    if (!await backend.restoreAuth(syncRepo)) return null;
    return backend;
  }

  Future<_RemoteBookState?> _loadRemoteBooks() async {
    final RemoteBookClient? client = await _resolveRemoteBookClient();
    _remoteBookClient = client;
    if (client == null) return null;
    try {
      final List<RemoteBookInfo> books = await client.listRemoteBooks();
      // #6: 远端与本地是同一本书时（同 bookKey）不在「配对设备」区重复展示。
      final List<EpubBookRow> localBooks =
          await appModel.database.getAllEpubBooks();
      final Set<String> localKeys =
          localBooks.map((EpubBookRow r) => r.bookKey).toSet();
      final List<RemoteBookInfo> withContent =
          books.where((RemoteBookInfo book) => book.hasContent).toList();
      return _RemoteBookState(
        books: dedupeRemoteBooks(
          remote: withContent,
          localBookKeys: localKeys,
          keyOf: sanitizeTtuFilename,
        ),
      );
    } catch (e) {
      debugPrint('[reader-shelf] remote book list failed: $e');
      return const _RemoteBookState(
        books: <RemoteBookInfo>[],
        failed: true,
      );
    }
  }

  void _refreshRemoteBooks() {
    setState(() {
      _remoteBooksFuture = _loadRemoteBooks();
    });
  }

  static double _gridExtent(BuildContext context, BoxConstraints constraints) {
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
                                buildBody(filtered, remoteSnapshot),
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
      icon: icon,
      onTap: onTap,
    );
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

  Widget _tagChip(BookTagRow tag) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: HibikiTagChip(
        label: tag.name,
        color: Color(tag.colorValue),
      ),
    );
  }

  Widget _overflowChip(int count) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: HibikiTagChip(
        label: '+$count',
      ),
    );
  }

  EdgeInsetsDirectional _cardTagChipPadding(HibikiDesignTokens tokens) {
    return EdgeInsetsDirectional.only(
      end: tokens.spacing.gap / 2,
      bottom: tokens.spacing.gap / 4,
    );
  }

  Widget _adaptiveTagColumn(List<BookTagRow> tags) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final int maxSlots = adaptiveTagSlots(
          maxHeight: constraints.maxHeight,
          tagCount: tags.length,
        );

        if (maxSlots >= tags.length) {
          return _uniformWidthTagColumn(
            [for (final tag in tags) _tagChip(tag)],
          );
        }

        final int visibleCount = maxSlots <= 1 ? 1 : maxSlots - 1;
        final int overflow = tags.length - visibleCount;
        return _uniformWidthTagColumn([
          for (final tag in tags.take(visibleCount)) _tagChip(tag),
          if (overflow > 0 && maxSlots > 1) _overflowChip(overflow),
        ]);
      },
    );
  }

  /// BUG-220(子2): 卡片左上角竖排标签原来用 `crossAxisAlignment.start`，每个 chip
  /// 宽度等于自身文字宽度，导致一行长一行短的参差。用 `IntrinsicWidth` 把整列宽度
  /// 收敛到最宽 chip，再用 `stretch` 让每个 chip 拉到该统一宽度（chip 内部文字仍左
  /// 对齐），竖排整齐。不改 [HibikiTagChip]，不影响别处用法。
  Widget _uniformWidthTagColumn(List<Widget> chips) {
    return IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: chips,
      ),
    );
  }

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
              if (srtBooks.isNotEmpty) ...[
                SliverToBoxAdapter(
                    child: _buildSectionHeader(t.srt_books_section)),
                SliverPadding(
                  padding: EdgeInsets.zero,
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: _gridExtent(context, constraints),
                      childAspectRatio: mediaSource.aspectRatio,
                    ),
                    itemCount: srtBooks.length,
                    itemBuilder: (_, i) => _buildSrtCard(srtBooks[i]),
                  ),
                ),
              ],
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
            if (srtBooks.isNotEmpty) ...[
              SliverToBoxAdapter(
                  child: _buildSectionHeader(t.srt_books_section)),
              SliverPadding(
                padding: EdgeInsets.zero,
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _gridExtent(context, constraints),
                    childAspectRatio: mediaSource.aspectRatio,
                  ),
                  itemCount: srtBooks.length,
                  itemBuilder: (_, i) => _buildSrtCard(srtBooks[i]),
                ),
              ),
            ],
            if (videoBooks.isNotEmpty) ...[
              SliverToBoxAdapter(
                  child: _buildSectionHeader(t.shelf_video_section)),
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _gridExtent(context, constraints),
                  childAspectRatio: mediaSource.aspectRatio,
                ),
                itemCount: videoBooks.length,
                itemBuilder: (_, i) => _buildVideoCard(videoBooks[i]),
              ),
            ],
            if (epubBooks.isNotEmpty) ...[
              if (srtBooks.isNotEmpty || videoBooks.isNotEmpty)
                SliverToBoxAdapter(child: _buildSectionHeader(t.section_epub)),
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _gridExtent(context, constraints),
                  childAspectRatio: mediaSource.aspectRatio,
                ),
                itemCount: epubBooks.length,
                itemBuilder: (_, i) => buildMediaItem(epubBooks[i]),
              ),
            ],
          ],
        ),
      ),
    );
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

  Widget _buildRemoteBookSection(
    _RemoteBookState state,
    BoxConstraints constraints,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.gap,
        tokens.spacing.rowHorizontal * 0.75,
        tokens.spacing.card,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.devices_other_outlined,
                size: 18,
                color: colors.primary,
              ),
              SizedBox(width: tokens.spacing.gap),
              Text(t.remote_book_interconnect, style: tokens.type.sectionLabel),
              SizedBox(width: tokens.spacing.gap),
              Text(
                t.remote_book_paired_device,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (state.failed)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: Text(
                t.remote_book_load_failed,
                style: textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            )
          else if (state.books.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            GridView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: _gridExtent(context, constraints),
                childAspectRatio: mediaSource.aspectRatio,
                crossAxisSpacing: tokens.spacing.gap,
                mainAxisSpacing: tokens.spacing.gap,
              ),
              itemCount: state.books.length,
              itemBuilder: (BuildContext context, int index) =>
                  _buildRemoteBookCard(state.books[index]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRemoteBookCard(RemoteBookInfo book) {
    final String safeKey = _safeRemoteBookKey(book.title);
    return _bookCardShell(
      cardKey: ValueKey<String>('remote_book_card_$safeKey'),
      focusId: HibikiFocusId('reader-shelf-remote-book-$safeKey'),
      onTap: () => _downloadRemoteBook(book),
      onLongPress: () => _downloadRemoteBook(book),
      child: _bookCardLayout(
        title: book.title,
        cover: _buildRemoteBookCover(book),
        coverBadge: _downloadingBooks.containsKey(book.title)
            ? RemoteDownloadProgressBadge(
                key: ValueKey<String>('remote_book_downloading_$safeKey'),
                progress: _downloadingBooks[book.title],
                tooltip: t.remote_book_downloading,
              )
            : IconButton.filledTonal(
                key: ValueKey<String>('remote_book_download_$safeKey'),
                tooltip: t.remote_book_download,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.download_outlined),
                onPressed: () => _downloadRemoteBook(book),
              ),
      ),
    );
  }

  Widget _buildRemoteBookCover(RemoteBookInfo book) {
    final String safeKey = _safeRemoteBookKey(book.title);
    final String? coverPath = book.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      return FadeInImage(
        key: ValueKey<String>('remote_book_cover_$safeKey'),
        imageErrorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.menu_book_outlined),
        placeholder: MemoryImage(kTransparentImage),
        image: FileImage(File(coverPath)),
        alignment: Alignment.topCenter,
        fit: BoxFit.fitHeight,
      );
    }
    final String? coverUrl = book.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Image.network(
        coverUrl,
        key: ValueKey<String>('remote_book_cover_$safeKey'),
        headers: remoteCoverHeadersFor(_remoteBookClient),
        alignment: Alignment.topCenter,
        fit: BoxFit.fitHeight,
        errorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.menu_book_outlined),
      );
    }
    return _coverPlaceholderIcon(Icons.menu_book_outlined);
  }

  Future<void> _downloadRemoteBook(RemoteBookInfo book) async {
    final RemoteBookClient? client = _remoteBookClient;
    // #3: 服务不可达 / 未鉴权时给明确提示，不再静默 return（用户点了像没反应）。
    if (client == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_book_unavailable)),
      );
      return;
    }
    // 同一本书已在下载中：忽略重复点击（卡片 tap/长按/按钮都指向这里）。
    if (_downloadingBooks.containsKey(book.title)) return;
    // #3: 标记下载中（先置不确定进度），卡片立刻显示进行中反馈。
    setState(() => _downloadingBooks[book.title] = null);
    try {
      final File dest = await _remoteBookDestination(book);
      await client.getRemoteBook(
        book.downloadId,
        dest,
        onProgress: (double progress) {
          if (!mounted) return;
          setState(() => _downloadingBooks[book.title] = progress);
        },
      );
      await _importRemoteBookFile(dest);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibikiHistoryPage.downloadRemoteBook', e, stack);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_book_download_failed)),
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _downloadingBooks.remove(book.title));
      } else {
        _downloadingBooks.remove(book.title);
      }
    }
    if (!mounted) return;
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    _refreshSrtBooks();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.remote_book_downloaded)),
    );
  }

  Future<File> _remoteBookDestination(RemoteBookInfo book) async {
    final Future<File> Function(RemoteBookInfo book)? injected =
        _pageWidget.remoteBookDownloadDestination;
    if (injected != null) return injected(book);
    final Directory temp = await getTemporaryDirectory();
    final Directory dir = Directory(p.join(temp.path, 'hibiki_remote_books'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${_safeRemoteBookKey(book.title)}.epub'));
  }

  Future<void> _importRemoteBookFile(File file) async {
    final Future<void> Function(File file)? injected =
        _pageWidget.remoteBookImporter;
    if (injected != null) {
      await injected(file);
      return;
    }
    await EpubImporter.importFromPath(
      db: appModel.database,
      filePath: file.path,
      fileName: p.basename(file.path),
    );
  }

  String _safeRemoteBookKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  Widget? _buildSrtBookTagLabels(int srtBookId) => _tagLabelsFromMap(
        ref.watch(srtBookTagMapProvider).valueOrNull,
        srtBookId,
      );

  Widget _buildSrtCard(SrtBook book) {
    final String selKey = 'srt_${book.uid}';
    final tagWidget = book.id != null ? _buildSrtBookTagLabels(book.id!) : null;
    final int? srtBookId = book.id;
    return _bookCardShell(
      cardKey: ValueKey<String>('srt_entry_${book.uid}'),
      focusId: HibikiFocusId('reader-shelf-srt-${book.uid}'),
      selectionKey: selKey,
      dragBookId: srtBookId,
      onTagDropped:
          srtBookId == null ? null : (tag) => _addTagToSrtBook(srtBookId, tag),
      onTap: () => _openSrtBook(book),
      onLongPress: () => _showSrtBookDialog(book),
      child: _bookCardLayout(
        title: book.title,
        cover: _buildSrtCover(book),
        tagLabels: tagWidget,
        coverBadge: _cardBadge(
          icon: Icons.subtitles_outlined,
          background: theme.colorScheme.secondaryContainer,
          foreground: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget? _buildVideoBookTagLabels(String bookUid) => _tagLabelsFromMap(
        ref.watch(videoBookTagMapProvider).valueOrNull,
        bookUid,
      );

  Widget _buildVideoCard(VideoBookRow book) {
    final tagWidget = _buildVideoBookTagLabels(book.bookUid);
    return _bookCardShell(
      cardKey: ValueKey<String>('video_entry_${book.bookUid}'),
      focusId: HibikiFocusId('reader-shelf-video-${book.bookUid}'),
      dragBookId: book.bookUid,
      onTagDropped: (tag) => _addTagToVideoBook(book.bookUid, tag),
      onTap: () => _openVideoBook(book),
      onLongPress: () => _showVideoBookDialog(book),
      child: _bookCardLayout(
        title: book.title,
        cover: _buildVideoCover(book),
        tagLabels: tagWidget,
        coverBadge: _cardBadge(
          icon: Icons.movie_outlined,
          background: theme.colorScheme.tertiaryContainer,
          foreground: theme.colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }

  Widget _buildVideoCover(VideoBookRow book) {
    final String? cover = book.coverPath;
    if (cover != null && File(cover).existsSync()) {
      return FadeInImage(
        imageErrorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.movie_outlined),
        placeholder: MemoryImage(kTransparentImage),
        image: FileImage(File(cover)),
        alignment: Alignment.topCenter,
        fit: BoxFit.fitHeight,
      );
    }
    return _coverPlaceholderIcon(Icons.movie_outlined);
  }

  void _openVideoBook(VideoBookRow book) {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => VideoHibikiPage.neutralized(
            bookUid: book.bookUid, repo: _videoRepo),
      ),
    );
  }

  Future<void> _openVideoImport() async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(repo: _videoRepo),
    );
    if (bookUid != null) {
      _refreshVideoBooks();
    }
  }

  Future<void> _addTagToVideoBook(String bookUid, BookTagRow tag) async {
    final existing = ref.read(videoBookTagMapProvider).valueOrNull;
    await _addTagToMedia(
      alreadyHas: existing?[bookUid]?.any((t) => t.id == tag.id) ?? false,
      tag: tag,
      addToDb: () =>
          ref.read(appProvider).database.addTagToVideoBook(bookUid, tag.id),
      invalidate: <ProviderOrFamily>[
        videoBookTagMapProvider,
        filteredVideoBookUidsProvider,
      ],
      // 视频用专属成功文案，区别于书籍入口（守卫 video_tags_menu_source_guard）。
      successMsg: t.tag_added_to_video(name: tag.name),
    );
  }

  /// 长按视频卡：弹底部菜单（编辑标签 / 设置封面 / 删除）。修复「视频长按没菜单」
  /// ——此前 onLongPress 与 onTap 同样只是打开播放页。与视频 tab 菜单保持一致。
  void _showVideoBookDialog(VideoBookRow book) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.sell_outlined),
              title: Text(t.tag_label),
              onTap: () {
                Navigator.pop(ctx);
                _openVideoTagPicker(book.bookUid);
              },
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: Text(t.srt_import_pick_cover),
              onTap: () {
                Navigator.pop(ctx);
                _pickVideoCover(book);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(
                t.dialog_delete,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteVideoBook(book);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openVideoTagPicker(String bookUid) {
    Navigator.push(
      context,
      adaptivePageRoute(
        builder: (_) => TagPickerPage(videoBookUid: bookUid),
      ),
    ).then((_) {
      ref.invalidate(videoBookTagMapProvider);
      ref.invalidate(filteredVideoBookUidsProvider);
      ref.invalidate(allTagsProvider);
    });
  }

  /// 设置视频封面：选图 → 经共享 [setVideoCoverFromPickedFile]（拷盘 + 驱逐旧
  /// 缓存 + 落库）→ 刷新。与视频 tab 换封面共用同一入口。
  Future<void> _pickVideoCover(VideoBookRow book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    final String? pickedPath = result?.files.first.path;
    if (pickedPath == null || !mounted) return;
    await setVideoCoverFromPickedFile(
      repo: _videoRepo,
      bookUid: book.bookUid,
      pickedPath: pickedPath,
    );
    if (mounted) _refreshVideoBooks();
  }

  /// 媒体删除确认对话框样板：弹 [ReaderHistoryDeleteDialog]，返回「用户确认了且本
  /// widget 仍挂载」。video/srt/epub 三处的 DB 删除 + 失效/刷新逻辑差异大、留在各方法；
  /// 仅这段对话框 + `confirmed != true || !mounted` 守卫收口于此（之前三份逐字复制）。
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

  Future<void> _confirmDeleteVideoBook(VideoBookRow book) async {
    if (!await _confirmMediaDelete(
      title: t.video_delete_title,
      message: t.video_delete_confirm(title: book.title),
    )) {
      return;
    }
    // ① 删 DB 行（含字幕 cue，事务内）。删前先抓被删 book 自己的封面/字幕路径——
    //    删后行没了就查不到了，删除回收要拿它来精确删自己的资产。
    final String? deletedCover = book.coverPath;
    final String? deletedSubtitle = book.subtitleSource;
    await _videoRepo.deleteVideoBook(book.bookUid);
    // ② 回收 app 拥有的封面/字幕副本：只删被删 book 自己那两个明确路径，并用「全库
    //    其余 book 的引用集」做护栏（仍被别本引用则保留）。绝不全库 sweep 字幕目录
    //    （那会误删别的播放列表各集的导入副本 = 永久数据丢失，BUG-276 复核退回）。
    //    videoPath 是用户原始文件、不在这两个目录里，绝不会被删。
    await _reclaimVideoDiskSpace(
      deletedBookUid: book.bookUid,
      deletedCoverPath: deletedCover,
      deletedSubtitlePath: deletedSubtitle,
    );
    if (mounted) {
      ref.invalidate(videoBookTagMapProvider);
      ref.invalidate(filteredVideoBookUidsProvider);
      _refreshVideoBooks();
    }
  }

  /// 删除视频后回收磁盘：精确删被删 book 自己的封面/字幕副本 + 安全的封面历史 GC
  /// + SQLite `VACUUM`（回收 freelist/WAL）。失败不应阻断删除流程（DB 行已删），
  /// 只记日志。VACUUM 必须在事务外调用。
  ///
  /// 关键：**不**对 `video_subtitles/` 做全库 sweep——播放列表只在 DB 存最后选中那集
  /// 的字幕路径，全库 sweep 会把别的播放列表各集的导入副本当孤儿删掉（永久数据丢失，
  /// BUG-276 复核退回）。字幕只删被删 book 自己 [deletedSubtitlePath]、且经「全库其余
  /// 引用集」护栏（仍被别本引用则保留）。封面文件名与 bookUid 1:1 绑定、引用集完整，
  /// 故可安全地全库清历史孤儿。
  Future<void> _reclaimVideoDiskSpace({
    required String deletedBookUid,
    required String? deletedCoverPath,
    required String? deletedSubtitlePath,
  }) async {
    try {
      // 删除后「全库其余 book」的引用集：被删 book 已不在 listAll，但仍显式排除其
      // uid 以防并发/事务时序，且用作封面历史 GC 的完整保留集。
      final ({Set<String> covers, Set<String> subtitles}) refs =
          await _videoRepo.collectReferencedAssetPaths(
        excludeBookUid: deletedBookUid,
      );
      // ① 精确删被删 book 自己的封面/字幕（仍被别本引用则保留）。
      await VideoStorage.deleteBookAssets(
        deletedCoverPath: deletedCoverPath,
        deletedSubtitlePath: deletedSubtitlePath,
        stillReferencedCoverPaths: refs.covers,
        stillReferencedSubtitlePaths: refs.subtitles,
      );
      // ② 安全的封面历史 GC：清掉已删视频遗留的孤儿封面（封面引用集完整）。
      await VideoStorage.gcOrphanCovers(referencedCoverPaths: refs.covers);
    } catch (e) {
      debugPrint('ReaderHistory: video asset GC failed: $e');
    }
    try {
      await appModel.database.customStatement('VACUUM');
      await appModel.database
          .customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      debugPrint('ReaderHistory: VACUUM after video delete failed: $e');
    }
  }

  Widget _buildSrtCover(SrtBook book) {
    if (book.coverPath != null && File(book.coverPath!).existsSync()) {
      return FadeInImage(
        imageErrorBuilder: (_, __, ___) => _coverPlaceholderIcon(
          Icons.subtitles_outlined,
        ),
        placeholder: MemoryImage(kTransparentImage),
        image: FileImage(File(book.coverPath!)),
        alignment: Alignment.topCenter,
        fit: BoxFit.fitHeight,
      );
    }
    return _coverPlaceholderIcon(Icons.subtitles_outlined);
  }

  Widget _coverPlaceholderIcon(IconData icon) {
    return Center(
      child: Icon(
        icon,
        size: 40,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _bookCardShell({
    required VoidCallback onTap,
    required VoidCallback onLongPress,
    required Widget child,
    Key? cardKey,
    HibikiFocusId? focusId,
    String? selectionKey,
    Object? dragBookId,
    void Function(BookTagRow tag)? onTagDropped,
  }) {
    final bool selected =
        selectionKey != null && _selectedKeys.contains(selectionKey);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color selectionColor = tokens.surfaces.primary;
    final double selectionInset = tokens.spacing.gap / 2;
    final double selectionPadding = tokens.spacing.gap / 4;
    final double selectionIconSize = tokens.spacing.gap * 1.75;
    // Gamepad long-press (hold A) on the focused card invokes the same
    // onLongPress as the mouse (book details / actions). In selection mode the
    // long-press is disabled (tap toggles selection), so it's a pass-through.
    final Widget card = GamepadLongPressActions(
      onLongPress: _selectionMode ? null : onLongPress,
      child: HibikiCard(
        key: cardKey,
        focusId: focusId,
        padding: EdgeInsets.zero,
        margin: EdgeInsets.all(tokens.spacing.rowVertical),
        selected: selected,
        onTap: _selectionMode && selectionKey != null
            ? () => _toggleSelection(selectionKey)
            : onTap,
        onLongPress: _selectionMode ? null : onLongPress,
        // 桌面端鼠标右键打开与长按相同的书籍上下文菜单（PC 用户惯例）。
        onSecondaryTap: _selectionMode ? null : onLongPress,
        child: AspectRatio(
          aspectRatio: mediaSource.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              if (_selectionMode && selectionKey != null)
                Positioned(
                  top: selectionInset,
                  left: selectionInset,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? selectionColor
                            : tokens.surfaces.page.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? selectionColor
                              : tokens.surfaces.outline,
                          width: 1.5,
                        ),
                      ),
                      padding: EdgeInsets.all(selectionPadding),
                      child: Icon(
                        Icons.check,
                        size: selectionIconSize,
                        color: selected
                            ? theme.colorScheme.onPrimary
                            : Colors.transparent,
                      ),
                    ),
                  ),
                ),
              if (selected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.surfaces.primary.withValues(alpha: 0.12),
                        borderRadius: tokens.radii.cardRadius,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (dragBookId == null || onTagDropped == null || _selectionMode) {
      return card;
    }
    return BookDragTarget(
      bookId: dragBookId,
      onTagDropped: onTagDropped,
      child: card,
    );
  }

  Widget _bookCardLayout({
    required String title,
    required Widget cover,
    Widget? tagLabels,
    Widget? coverBadge,
    Widget? metadata,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    // 书名压在封面内（底部渐变暗角），封面铺满整张卡片不被下方 footer 压缩；
    // 右上角类型徽章（TODO-284）、左上角标签、底部进度条均叠加在封面上。
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(child: cover),
        _titleOverlay(title),
        if (metadata != null)
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: 0,
            child: metadata,
          ),
        if (coverBadge != null)
          PositionedDirectional(
            end: overlayInset,
            top: overlayInset,
            // 封面右上角类型徽章（TODO-284 / TODO-355 / TODO-361）。徽章内在尺寸
            // 是 22px（HibikiBadge: icon 14 + padding gap）。早期徽章夹在封面下方的
            // footer 文字行里，紧贴小号书名，视觉上读作约「半个」封面元素；TODO-355 把
            // 徽章挪到封面图上后，旧的 `SizedBox.square(gap*5=40) + scaleDown` 永远不会
            // 缩小 22px 的徽章，于是在封面图上读起来比原来「大了一圈」。这里改成
            // `gap*2=16` 的方框 + `BoxFit.contain`，把徽章等比缩到约 16px，恢复书架
            // 原来那种克制的小角标观感（≈用户记忆里的 0.5 显示）。
            child: SizedBox.square(
              dimension: kShelfCoverBadgeDimension,
              child: FittedBox(
                fit: BoxFit.contain,
                child: coverBadge,
              ),
            ),
          ),
        if (tagLabels != null)
          PositionedDirectional(
            start: overlayInset,
            top: overlayInset,
            child: _bookCardTagArea(tagLabels),
          ),
      ],
    );
  }

  Widget _titleOverlay(String title) {
    return LayoutBuilder(builder: (context, constraints) {
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: constraints.maxHeight * 0.38,
          width: double.infinity,
          alignment: Alignment.bottomCenter,
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.spacing.gap * 0.75,
            tokens.spacing.gap / 2,
            tokens.spacing.gap * 0.75,
            tokens.spacing.gap * 0.75,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tokens.surfaces.page.withValues(alpha: 0),
                tokens.surfaces.page.withValues(alpha: 0.85),
              ],
            ),
          ),
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
            softWrap: true,
            style: textTheme.labelSmall?.copyWith(
              color: tokens.surfaces.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    });
  }

  Widget _bookCardTagArea(Widget tagLabels) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: tokens.spacing.gap * 9,
        maxHeight: tokens.spacing.gap * 3.5,
      ),
      child: ClipRect(child: tagLabels),
    );
  }

  Widget _cardBadge({
    required IconData icon,
    required Color background,
    required Color foreground,
  }) {
    return HibikiBadge(
      icon: icon,
      background: background,
      foreground: foreground,
    );
  }

  MediaItem _srtBookMediaItem(SrtBook book) {
    return MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(book.bookKey),
      title: book.title,
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
      imageUrl:
          book.coverPath != null ? Uri.file(book.coverPath!).toString() : null,
    );
  }

  void _openSrtBook(SrtBook book) {
    if (book.bookKey.isEmpty) {
      HibikiToast.show(msg: t.srt_epub_not_ready);
      return;
    }
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => HibikiAppUiScaleNeutralizer(
          child: ReaderHibikiPage(
            bookKey: book.bookKey,
            item: _srtBookMediaItem(book),
          ),
        ),
      ),
    );
  }

  List<DialogAction> _srtExtraActions(
      BuildContext dialogContext, SrtBook book) {
    final String bookKey = book.bookKey;
    final MediaItem item = _srtBookMediaItem(book);
    return [
      DialogDangerAction(
        label: t.dialog_delete,
        onPressed: () async {
          Navigator.pop(dialogContext);
          await _confirmDeleteSrtBook(book);
        },
      ),
      DialogQuickAction(
        label: t.srt_import_pick_cover,
        icon: Icons.image_outlined,
        onPressed: () async {
          Navigator.pop(dialogContext);
          await _pickSrtBookCover(book);
        },
      ),
      if (book.id != null)
        DialogQuickAction(
          label: t.tag_label,
          icon: Icons.sell_outlined,
          onPressed: () => _openSrtBookTagPicker(book.id!),
        ),
      if (bookKey.isNotEmpty) ...[
        DialogQuickAction(
          label: t.audio_import,
          icon: Icons.headphones_outlined,
          onPressed: () => _openAudioImport(item, bookKey),
        ),
        DialogListAction(
          label: t.profile_book_profile,
          icon: Icons.account_circle_outlined,
          onPressed: () => _openBookProfilePicker(item, bookKey),
        ),
        DialogListAction(
          label: t.book_css_editor_edit_css,
          icon: Icons.code_outlined,
          onPressed: () {
            Navigator.pop(dialogContext);
            _openCssEditor(bookKey);
          },
        ),
      ],
    ];
  }

  Future<void> _showSrtBookDialog(SrtBook book) async {
    await showAppDialog(
      context: context,
      builder: (ctx) => MediaItemDialogPage(
        item: _srtBookMediaItem(book),
        isHistory: true,
        extraActions: (_) => _srtExtraActions(ctx, book),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _pickSrtBookCover(SrtBook book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result == null || !mounted) return;
    final String? pickedPath = result.files.first.path;
    if (pickedPath == null) return;

    final Directory persistDir =
        await AudiobookStorage.ensurePersistDir(book.uid);
    final String ext = p.extension(pickedPath);
    final String dest = p.join(persistDir.path, 'cover$ext');
    await File(pickedPath).copy(dest);

    book.coverPath = dest;
    await SrtBookRepository(appModel.database).save(book);
    if (mounted) setState(() {});
  }

  void _selectAll() {
    setState(() {
      for (final item in _visibleEpubBooks) {
        _selectedKeys.add(item.mediaIdentifier);
      }
      for (final book in _visibleSrtBooks) {
        _selectedKeys.add('srt_${book.uid}');
      }
    });
  }

  void _invertSelection() {
    setState(() {
      final Set<String> allKeys = {
        for (final item in _visibleEpubBooks) item.mediaIdentifier,
        for (final book in _visibleSrtBooks) 'srt_${book.uid}',
      };
      final Set<String> inverted = allKeys.difference(_selectedKeys);
      _selectedKeys
        ..clear()
        ..addAll(inverted);
    });
  }

  Widget _buildBatchActionBar() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card - tokens.spacing.gap / 2,
            vertical: tokens.spacing.gap,
          ),
          child: Row(
            children: [
              Text(
                t.batch_selected_count(n: _selectedKeys.length),
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              TextButton(
                onPressed: _selectAll,
                child: Text(t.batch_select_all),
              ),
              TextButton(
                onPressed: _invertSelection,
                child: Text(t.batch_invert_selection),
              ),
              const Spacer(),
              HibikiIconButton(
                enabled: _selectedKeys.isNotEmpty,
                onTap: _batchShowTagPicker,
                icon: Icons.sell_outlined,
                tooltip: t.tag_label,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              HibikiIconButton(
                enabled: _selectedKeys.isNotEmpty,
                onTap: _batchDeleteConfirm,
                icon: Icons.delete_outline,
                tooltip: t.dialog_delete,
                enabledColor: theme.colorScheme.error,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _batchDeleteConfirm() async {
    final int count = _selectedKeys.length;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: t.dialog_delete,
        message: t.batch_delete_confirm(n: count),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;

    int deleted = 0;
    final Set<String> toDelete = Set.of(_selectedKeys);
    for (final key in toDelete) {
      if (key.startsWith('srt_')) {
        final String uid = key.substring(4);
        final SrtBookRepository repo = SrtBookRepository(appModel.database);
        final SrtBook? book = await repo.findByUid(uid);
        if (book != null) {
          if (book.bookKey.isNotEmpty) {
            await ReaderHibikiSource.instance.deleteBook(
              db: appModel.database,
              bookKey: book.bookKey,
            );
          }
          await repo.delete(uid);
          deleted++;
        }
      } else {
        final String? bookKey = _parseBookKey(key);
        if (bookKey != null) {
          final bool ok = await ReaderHibikiSource.instance.deleteBook(
            db: appModel.database,
            bookKey: bookKey,
          );
          if (ok) deleted++;
        }
      }
    }
    if (!mounted) return;
    _refreshSrtBooks();
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    _exitSelectionMode();
    HibikiToast.show(msg: t.batch_delete_success(n: deleted));
  }

  Future<void> _batchShowTagPicker() async {
    final allTags = ref.read(allTagsProvider).valueOrNull;
    if (allTags == null || allTags.isEmpty) {
      HibikiToast.show(msg: t.tag_no_tags_hint);
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (_) => _BatchTagPickerDialog(
        allTags: allTags,
        selectedKeys: _selectedKeys,
        database: appModel.database,
        parseBookKey: _parseBookKey,
      ),
    );
    if (!mounted) return;
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    ref.invalidate(filteredBookIdsProvider);
    ref.invalidate(filteredSrtBookIdsProvider);
  }

  Future<void> _confirmDeleteSrtBook(SrtBook book) async {
    if (!await _confirmMediaDelete(
      title: t.srt_delete_title,
      message: t.srt_delete_confirm(title: book.title),
    )) {
      return;
    }

    if (book.bookKey.isNotEmpty) {
      await ReaderHibikiSource.instance.deleteBook(
        db: appModel.database,
        bookKey: book.bookKey,
      );
    }
    await SrtBookRepository(appModel.database).delete(book.uid);
    if (mounted) {
      _refreshSrtBooks();
      ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
      setState(() {});
    }
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
        fit: BoxFit.fitHeight,
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

  Widget _progressBar(MediaItem item) {
    double value = 0;
    if (item.duration > 0) {
      final double v = item.position / item.duration;
      if (v.isFinite) {
        value = v > 0.97 ? 1 : v;
      }
    }
    return LinearProgressIndicator(
      value: value,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      color: theme.colorScheme.primary,
      minHeight: 3,
    );
  }

  Widget _audiobookBadge(HealthKind kind) {
    final ColorScheme cs = theme.colorScheme;
    final Color bg;
    final Color fg;
    switch (kind) {
      case HealthKind.failed:
        bg = cs.errorContainer;
        fg = cs.onErrorContainer;
      case HealthKind.partial:
        bg = cs.tertiaryContainer;
        fg = cs.onTertiaryContainer;
      case HealthKind.ok:
      case HealthKind.unrun:
      case HealthKind.running:
      case HealthKind.notApplicable:
        bg = cs.secondaryContainer;
        fg = cs.onSecondaryContainer;
    }
    return _cardBadge(
      icon: Icons.headphones_outlined,
      background: bg,
      foreground: fg,
    );
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
      DialogQuickAction(
        label: t.tag_label,
        icon: Icons.sell_outlined,
        onPressed: () => _openTagPicker(bookKey),
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

  /// 该书当前是否就是活动后台听书会话。
  bool _isBackgroundListeningBook(String bookKey) {
    final session = appModel.audiobookSession;
    return session.isActive && session.book?.bookKey == bookKey;
  }

  /// 书架长按菜单切「后台听书」（TODO-291 阶段2）。
  /// - 该书已是活动会话 → 停止后台听书。
  /// - 否则 → 启动该书的后台听书会话（无正在播用该书启动；有别的书在播则顶掉切到该书），
  ///   并拉起悬浮窗。无可播放音频时提示。
  Future<void> _toggleFloatingLyricFromShelf(String bookKey) async {
    Navigator.pop(context);
    if (_isBackgroundListeningBook(bookKey)) {
      await appModel.stopBackgroundListening();
      if (mounted) setState(() {});
      return;
    }
    final BackgroundListenResult result =
        await appModel.startBackgroundListening(bookKey);
    if (!mounted) return;
    switch (result) {
      case BackgroundListenResult.started:
        break;
      case BackgroundListenResult.noAudio:
        HibikiToast.show(msg: t.floating_lyric_no_audio);
        break;
      case BackgroundListenResult.loadFailed:
        HibikiToast.show(msg: t.audiobook_load_error);
        break;
    }
    setState(() {});
  }

  Future<void> _confirmDeleteEpub(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    if (!await _confirmMediaDelete(
      title: t.epub_delete_title,
      message: t.srt_delete_confirm(title: item.title),
    )) {
      return;
    }

    final bool ok = await ReaderHibikiSource.instance.deleteBook(
      db: appModel.database,
      bookKey: bookKey,
    );
    if (!mounted) return;
    if (!ok) {
      HibikiToast.show(msg: t.epub_delete_error);
      return;
    }
    _refreshSrtBooks();
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    setState(() {});
  }

  String? _parseBookKey(String mediaIdentifier) =>
      ReaderHibikiSource.parseBookKey(mediaIdentifier);

  Future<void> _openIllustrations(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted || row == null) return;
    Navigator.push(
      context,
      adaptivePageRoute(
        builder: (_) => IllustrationsViewerPage(
          bookTitle: item.title,
          extractDir: row.extractDir,
        ),
      ),
    );
  }

  Future<void> _openAudioImport(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
        audioOnly: true,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openAudiobookImport(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  // ── 拖拽导入（books 表面） ──────────────────────────────────────────────────

  /// 文件拖入书架后的路由：分类 → 命中测试 → 决策 → 打开对应对话框/提示。
  /// [localPosition] 为相对 [HibikiFileDropTarget] 的局部坐标，需转屏幕坐标
  /// 后才能与卡片登记表（用屏幕矩形）命中测试。
  void _handleShelfDrop(List<String> paths, Offset localPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final DroppedFiles files = classifyDroppedFiles(paths);
    final RenderObject? ro = context.findRenderObject();
    Offset global = localPosition;
    if (ro is RenderBox && ro.attached) {
      global = ro.localToGlobal(localPosition);
    }
    final String? hitBookKey = _cardDropRegistry.hitTest(global);
    final DropIntent intent = decideDropIntent(
      surface: DropSurface.books,
      files: files,
      cardHit: hitBookKey != null,
    );
    switch (intent) {
      case DropIntent.importNewBook:
        _openBookImportPrefilled(
          epubPath: files.books.first,
          subtitlePath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.attachToBookCard:
        _openAudiobookPrefilled(
          bookKey: hitBookKey!,
          audioPaths: files.audios,
          alignmentPath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.needCardTarget:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_need_card_target)),
        );
      case DropIntent.importNewVideo:
      case DropIntent.importNewPlaylist:
      case DropIntent.attachToVideoCard:
      case DropIntent.ignore:
        break;
    }
  }

  /// 拖入书文件 → 打开 [BookImportDialog]，预填 EPUB（及可选字幕）路径。
  /// 复用 [ReaderHibikiSource.buildBookImportButton] 的 repo/打开/刷新范式。
  Future<void> _openBookImportPrefilled({
    required String epubPath,
    required String? subtitlePath,
  }) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialEpubPath: epubPath,
        initialSubtitlePath: subtitlePath,
      ),
    );
    if (imported == true && mounted) {
      _refreshSrtBooks();
      ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
    }
  }

  /// 拖入字幕/音频到书卡 → 打开 [AudiobookImportDialog] 附加到该书，预填音频/对齐路径。
  /// 复用 [_openAudiobookImport] 的 extractDir 取法与刷新范式（此处无外层对话框需 pop）。
  Future<void> _openAudiobookPrefilled({
    required String bookKey,
    required List<String> audioPaths,
    required String? alignmentPath,
  }) async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
        initialAlignmentPath: alignmentPath,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _openTagPicker(String bookKey) {
    Navigator.pop(context);
    Navigator.push(
      context,
      adaptivePageRoute(builder: (_) => TagPickerPage(bookKey: bookKey)),
    ).then((_) {
      ref.invalidate(bookTagMapProvider);
      ref.invalidate(filteredBookIdsProvider);
      ref.invalidate(allTagsProvider);
    });
  }

  void _openSrtBookTagPicker(int srtBookId) {
    Navigator.pop(context);
    Navigator.push(
      context,
      adaptivePageRoute(
        builder: (_) => TagPickerPage(srtBookId: srtBookId, isSrtBook: true),
      ),
    ).then((_) {
      ref.invalidate(srtBookTagMapProvider);
      ref.invalidate(filteredSrtBookIdsProvider);
      ref.invalidate(allTagsProvider);
    });
  }

  Future<void> _openCssEditor(String bookKey) async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    final String extractDir = row?.extractDir ?? '';
    final bool exists = await EpubStorage.bookDirExists(extractDir);
    if (!exists) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.book_css_editor_no_extract_dir)),
        );
      }
      return;
    }
    if (mounted) {
      await Navigator.push(
        context,
        adaptivePageRoute<void>(
          builder: (_) => BookCssEditorPage(extractDir: extractDir),
        ),
      );
    }
  }

  void _openBookProfilePicker(MediaItem item, String bookKey) {
    Navigator.pop(context);
    final String bookUid = bookKey;
    final ProfileRepository profileRepo = ref.read(profileRepositoryProvider);
    final ProfileUiState profileState = ref.read(profileViewModelProvider);

    showAppDialog<void>(
      context: context,
      builder: (ctx) => _BookProfileDialog(
        bookUid: bookUid,
        profileRepo: profileRepo,
        profiles: profileState.profiles,
        activeProfileName: profileState.activeProfile?.name ?? '',
      ),
    );
  }
}

@visibleForTesting
class ReaderHistoryDeleteDialog extends StatelessWidget {
  const ReaderHistoryDeleteDialog({
    required this.title,
    required this.message,
    required this.onConfirm,
    super.key,
  });

  final String title;
  final String message;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: title,
        leadingIcon: Icons.delete_outline,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          message,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: onConfirm,
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookProfileDialog extends StatefulWidget {
  const _BookProfileDialog({
    required this.bookUid,
    required this.profileRepo,
    required this.profiles,
    required this.activeProfileName,
  });

  final String bookUid;
  final ProfileRepository profileRepo;
  final List<ProfileRow> profiles;
  final String activeProfileName;

  @override
  State<_BookProfileDialog> createState() => _BookProfileDialogState();
}

class _BookProfileDialogState extends State<_BookProfileDialog> {
  int? _selectedProfileId;
  bool _loading = true;
  late List<ProfileRow> _profiles;
  late String _activeProfileName;

  @override
  void initState() {
    super.initState();
    _profiles = widget.profiles;
    _activeProfileName = widget.activeProfileName;
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final int? current =
        await widget.profileRepo.getBookProfileId(widget.bookUid);

    if (_profiles.isEmpty || _activeProfileName.isEmpty) {
      _profiles = await widget.profileRepo.getAllProfiles();
      final int activeId = await widget.profileRepo.getActiveProfileId();
      for (final p in _profiles) {
        if (p.id == activeId) {
          _activeProfileName = p.name;
          break;
        }
      }
      if (_activeProfileName.isEmpty && _profiles.isNotEmpty) {
        _activeProfileName = _profiles.first.name;
      }
    }

    if (mounted) {
      setState(() {
        _selectedProfileId = current;
        _loading = false;
      });
    }
  }

  Future<void> _onChanged(int? profileId) async {
    setState(() => _selectedProfileId = profileId);
    if (profileId == null) {
      await widget.profileRepo.removeBookProfile(widget.bookUid);
    } else {
      await widget.profileRepo.setBookProfile(widget.bookUid, profileId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BookProfileDialogFrame(
      loading: _loading,
      activeProfileName: _activeProfileName,
      profiles: _profiles,
      selectedProfileId: _selectedProfileId,
      onChanged: _onChanged,
      onClose: () => Navigator.pop(context),
    );
  }
}

@visibleForTesting
class BookProfileDialogFrame extends StatelessWidget {
  const BookProfileDialogFrame({
    required this.loading,
    required this.activeProfileName,
    required this.profiles,
    required this.selectedProfileId,
    required this.onChanged,
    required this.onClose,
    super.key,
  });

  final bool loading;
  final String activeProfileName;
  final List<ProfileRow> profiles;
  final int? selectedProfileId;
  final ValueChanged<int?> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 500,
      maxHeightFactor: 0.86,
      // HibikiModalSheetFrame manages its own header/body/footer layout and
      // scrolls its body internally. Leaving the dialog frame's default
      // scrollable:true would wrap it in a second SingleChildScrollView, giving
      // a confusing nested outer+inner double scroll. scrollable:false makes the
      // ConstrainedBox bound the sheet directly, matching every other dialog.
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.profile_book_profile,
        leadingIcon: Icons.manage_accounts_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: loading
            ? SizedBox(
                height: 64,
                child: Center(child: adaptiveIndicator(context: context)),
              )
            : BookProfileDialogContent(
                activeProfileName: activeProfileName,
                profiles: profiles,
                selectedProfileId: selectedProfileId,
                onChanged: onChanged,
              ),
        footer: Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: onClose,
            child: Text(t.dialog_close),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class BookProfileDialogContent extends StatelessWidget {
  const BookProfileDialogContent({
    required this.activeProfileName,
    required this.profiles,
    required this.selectedProfileId,
    required this.onChanged,
    super.key,
  });

  final String activeProfileName;
  final List<ProfileRow> profiles;
  final int? selectedProfileId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.46,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            AdaptiveSettingsSection(
              children: [
                _BookProfileOptionRow(
                  title: t.profile_follow_default_current(
                    name: activeProfileName,
                  ),
                  selected: selectedProfileId == null,
                  onTap: () => onChanged(null),
                ),
                for (final profile in profiles)
                  _BookProfileOptionRow(
                    title: profile.name,
                    selected: selectedProfileId == profile.id,
                    onTap: () => onChanged(profile.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BookProfileOptionRow extends StatelessWidget {
  const _BookProfileOptionRow({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final Color selectedColor = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : Theme.of(context).colorScheme.primary;
    final Color idleColor = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return AdaptiveSettingsRow(
      title: title,
      onTap: onTap,
      trailing: Icon(
        selected
            ? (cupertino
                ? CupertinoIcons.check_mark
                : Icons.radio_button_checked)
            : (cupertino ? CupertinoIcons.circle : Icons.radio_button_off),
        size: cupertino ? 20 : 22,
        color: selected ? selectedColor : idleColor,
      ),
    );
  }
}

class _BatchTagPickerDialog extends StatefulWidget {
  const _BatchTagPickerDialog({
    required this.allTags,
    required this.selectedKeys,
    required this.database,
    required this.parseBookKey,
  });

  final List<BookTagRow> allTags;
  final Set<String> selectedKeys;
  final HibikiDatabase database;
  final String? Function(String) parseBookKey;

  @override
  State<_BatchTagPickerDialog> createState() => _BatchTagPickerDialogState();
}

class _BatchTagPickerDialogState extends State<_BatchTagPickerDialog> {
  final Set<int> _addTagIds = {};
  final Set<int> _removeTagIds = {};

  Future<void> _apply() async {
    final tr = Translations.of(context);
    final db = widget.database;

    final List<String> epubBookKeys = [];
    final List<String> srtUids = [];
    for (final key in widget.selectedKeys) {
      if (key.startsWith('srt_')) {
        srtUids.add(key.substring(4));
      } else {
        final String? bookKey = widget.parseBookKey(key);
        if (bookKey != null) epubBookKeys.add(bookKey);
      }
    }

    final List<int> srtBookIds = await _resolveSrtBookIds(srtUids);

    for (final tagId in _addTagIds) {
      for (final bookKey in epubBookKeys) {
        await db.addTagToBook(bookKey, tagId);
      }
      for (final srtId in srtBookIds) {
        await db.addTagToSrtBook(srtId, tagId);
      }
    }
    for (final tagId in _removeTagIds) {
      for (final bookKey in epubBookKeys) {
        await db.removeTagFromBook(bookKey, tagId);
      }
      for (final srtId in srtBookIds) {
        await db.removeTagFromSrtBook(srtId, tagId);
      }
    }

    if (!mounted) return;
    for (final tagId in _addTagIds) {
      final tag = widget.allTags.firstWhere((row) => row.id == tagId);
      HibikiToast.show(
        msg: tr.batch_tag_added(
          name: tag.name,
          n: widget.selectedKeys.length,
        ),
      );
    }
    for (final tagId in _removeTagIds) {
      final tag = widget.allTags.firstWhere((row) => row.id == tagId);
      HibikiToast.show(
        msg: tr.batch_tag_removed(
          name: tag.name,
          n: widget.selectedKeys.length,
        ),
      );
    }
    Navigator.pop(context);
  }

  Future<List<int>> _resolveSrtBookIds(List<String> uids) async {
    final List<int> ids = [];
    final repo = SrtBookRepository(widget.database);
    for (final uid in uids) {
      final book = await repo.findByUid(uid);
      if (book?.id != null) ids.add(book!.id!);
    }
    return ids;
  }

  void _setTagIntent(BookTagRow tag, _BatchTagIntent intent) {
    setState(() {
      _addTagIds.remove(tag.id);
      _removeTagIds.remove(tag.id);
      switch (intent) {
        case _BatchTagIntent.keep:
          break;
        case _BatchTagIntent.add:
          _addTagIds.add(tag.id);
        case _BatchTagIntent.remove:
          _removeTagIds.add(tag.id);
      }
    });
  }

  _BatchTagIntent _tagIntent(BookTagRow tag) {
    if (_addTagIds.contains(tag.id)) return _BatchTagIntent.add;
    if (_removeTagIds.contains(tag.id)) return _BatchTagIntent.remove;
    return _BatchTagIntent.keep;
  }

  @override
  Widget build(BuildContext context) {
    return ReaderHistoryBatchTagDialogFrame(
      canApply: _addTagIds.isNotEmpty || _removeTagIds.isNotEmpty,
      onApply: _apply,
      body: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.allTags.length,
        itemBuilder: (_, i) {
          final tag = widget.allTags[i];
          return _BatchTagIntentRow(
            tag: tag,
            selected: _tagIntent(tag),
            onChanged: (intent) => _setTagIntent(tag, intent),
          );
        },
      ),
    );
  }
}

@visibleForTesting
class ReaderHistoryBatchTagDialogFrame extends StatelessWidget {
  const ReaderHistoryBatchTagDialogFrame({
    required this.body,
    required this.canApply,
    required this.onApply,
    super.key,
  });

  final Widget body;
  final bool canApply;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.batch_tag_title,
        leadingIcon: Icons.sell_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: body,
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: canApply ? onApply : null,
              child: Text(t.batch_tag_apply),
            ),
          ],
        ),
      ),
    );
  }
}

enum _BatchTagIntent { keep, add, remove }

class _BatchTagIntentRow extends StatelessWidget {
  const _BatchTagIntentRow({
    required this.tag,
    required this.selected,
    required this.onChanged,
  });

  final BookTagRow tag;
  final _BatchTagIntent selected;
  final ValueChanged<_BatchTagIntent> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color tagColor = Color(tag.colorValue);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    // TODO-308: 三段意图原来用 keep=`horizontal_rule`、remove=`remove` 两个几乎
    // 一样的横杠（语义相反却长得一样），且纯图标无可见文字（tooltip 只有桌面悬停
    // 才出，手机/手柄看不到）。这里给每段配语义区分的图标 + 颜色 + 可见文字标签
    // （复用已有 i18n key），三段一眼可辨：
    //   keep   = 中性灰 圈内横杠（不改动）
    //   add    = 主色   实心加号圈（添加）
    //   remove = 错误红 禁止圈（移除，整段连文字一起染红）
    final Color removeColor = colors.error;
    final Color addColor = colors.primary;
    final Color keepColor = colors.onSurfaceVariant;

    Widget segmentLabel(String text, _BatchTagIntent intent, Color color) {
      return Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: selected == intent ? color : null,
        ),
      );
    }

    return AdaptiveSettingsRow(
      title: tag.name,
      icon: cupertino ? CupertinoIcons.tag : Icons.sell_outlined,
      controlBelow: true,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: tagColor,
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 12, height: 12),
            ),
            SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
            Flexible(
              child: adaptiveSegmentedButton<_BatchTagIntent>(
                context: context,
                segments: [
                  ButtonSegment<_BatchTagIntent>(
                    value: _BatchTagIntent.keep,
                    tooltip: t.batch_tag_keep,
                    label: segmentLabel(
                        t.batch_tag_keep, _BatchTagIntent.keep, keepColor),
                    icon: Icon(
                      cupertino
                          ? CupertinoIcons.minus_circle
                          : Icons.remove_circle_outline,
                      size: 16,
                      color:
                          selected == _BatchTagIntent.keep ? keepColor : null,
                    ),
                  ),
                  ButtonSegment<_BatchTagIntent>(
                    value: _BatchTagIntent.add,
                    tooltip: t.batch_tag_add,
                    label: segmentLabel(
                        t.batch_tag_add, _BatchTagIntent.add, addColor),
                    icon: Icon(
                      cupertino ? CupertinoIcons.add_circled : Icons.add_circle,
                      size: 16,
                      color: selected == _BatchTagIntent.add ? addColor : null,
                    ),
                  ),
                  ButtonSegment<_BatchTagIntent>(
                    value: _BatchTagIntent.remove,
                    tooltip: t.batch_tag_remove,
                    label: segmentLabel(t.batch_tag_remove,
                        _BatchTagIntent.remove, removeColor),
                    icon: Icon(
                      cupertino
                          ? CupertinoIcons.minus_circle_fill
                          : Icons.do_not_disturb_on,
                      size: 16,
                      color: selected == _BatchTagIntent.remove
                          ? removeColor
                          : null,
                    ),
                  ),
                ],
                selected: {selected},
                onSelectionChanged: (values) {
                  if (values.isNotEmpty) onChanged(values.first);
                },
                style: kSettingsSegmentedStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// TODO-308 测试钩子：渲染批量打标签的「保持 / 添加 / 移除」三段意图行，供 widget
/// 守卫断言三段各有可见文字标签与语义区分的图标（不再是两个一样的横杠）。
/// [selectedIndex] 0=keep / 1=add / 2=remove。
@visibleForTesting
Widget buildBatchTagIntentRowForTesting({
  required BookTagRow tag,
  int selectedIndex = 0,
}) {
  const List<_BatchTagIntent> intents = <_BatchTagIntent>[
    _BatchTagIntent.keep,
    _BatchTagIntent.add,
    _BatchTagIntent.remove,
  ];
  return _BatchTagIntentRow(
    tag: tag,
    selected: intents[selectedIndex],
    onChanged: (_) {},
  );
}

class _AudiobookInfo {
  const _AudiobookInfo({required this.hasAudiobook, required this.healthKind});
  final bool hasAudiobook;
  final HealthKind healthKind;
}

class _RemoteBookState {
  const _RemoteBookState({
    required this.books,
    this.failed = false,
  });

  final List<RemoteBookInfo> books;
  final bool failed;
}
