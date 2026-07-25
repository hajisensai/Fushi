import 'dart:async' show unawaited;
import 'dart:io';

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
import 'package:hibiki/src/media/display_title.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/pages/implementations/book_drag_target.dart';
import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki_core/hibiki_core.dart';
// BUG-813：构造 ReaderPositionsCompanion 回填下载书的阅读进度需要 drift 的 Value（
// hibiki_core 未再导出它）。
import 'package:drift/drift.dart' show Value;
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:hibiki/src/media/collections/add_to_collection_dialog.dart';
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
import 'package:hibiki/src/sync/deletion_propagation.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/manual_sync_ui.dart';
import 'package:hibiki/src/sync/remote_download_progress_badge.dart';
import 'package:hibiki/src/sync/remote_cover_image.dart';
import 'package:hibiki/src/sync/remote_book_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_progress_banner.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/components/batch_tag_dialog_frame.dart';
import 'package:hibiki/src/utils/cover_image.dart';

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

  // BUG-728：EPUB-backed 有声书在书架**只渲染成 SRT 卡**（其 EpubBooks 行被
  // `srtBookKeys` 过滤出 EPUB 卡列表），而 SRT 卡以前不画进度条。这里收录当前
  // `books`（hibikiBooksProvider）里每本 EpubBooks 行**已算好的** position/duration
  // （经 [ReaderHibikiSource.computeBookProgress]，含听书 normCharOffset 回退），
  // 供 SRT 卡按 bookKey 复用同一进度，无需重复读 DB / 重算。
  Map<String, ({int position, int duration})> _epubProgressByBookKey = const {};

  Future<_RemoteBookState?>? _remoteBooksFuture;
  // BUG-992：上次成功的远端书态，自动刷新重拉（future→waiting）时沿用，避免闪屏。
  _RemoteBookState? _lastRemoteState;

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

  /// 已标记「读完」的书 bookKey 集合（EpubBooks.completedAt 非 null 的单一真值）。
  /// EPUB 小说卡按自身 bookKey、有声书 SRT 卡按其配对 bookKey 命中同一集合，供概览
  /// 「Completed」统计、卡片完成视觉、菜单「标记/取消」标签联动。随 [_loadShelfMaps]
  /// 一次性预取，手动切换或删书后 `_shelfMapsFuture = _loadShelfMaps()` 重取。
  Set<String> _completedBookKeys = const <String>{};

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

  /// 正在下载有声书包的本地书（key = 导入后的本地 bookKey，BUG-990）。远端有声书
  /// 走「先下 EPUB 后下有声书」两阶段：EPUB 一落库，书架 provider 自动刷新把远端占位
  /// 卡（带下载转圈）顶替成本地卡，此刻有声书还没落库 → 本地卡若无指示就露出「无转圈
  /// 的普通书」。下载有声书期间把本地 bookKey 记进这里，本地 EPUB 卡 / SRT 卡据此继续
  /// 显示加载覆盖层，直到有声书下完（成功或失败都在 finally 清除）。
  final Set<String> _downloadingAudiobookKeys = <String>{};

  /// 本地卡在「有声书还在下」时叠的居中加载覆盖层（BUG-990）；[bookKey] 不在下载集合
  /// 时返回 null（不叠）。
  Widget? _audiobookDownloadingOverlay(String? bookKey) {
    if (bookKey == null || !_downloadingAudiobookKeys.contains(bookKey)) {
      return null;
    }
    return RemoteDownloadProgressBadge(
      key: ValueKey<String>('audiobook_downloading_$bookKey'),
      progress: null,
      tooltip: t.remote_book_downloading,
    );
  }

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
  void initState() {
    super.initState();
    // 后台同步（关书后 / 启动）把合集成员落库后，只会 refreshTab() 通知本 tab；但
    // 折叠映射（_collectionsById / _primaryCollectionByEntry / _memberSortIndex）走
    // 非响应式的 _shelfMapsFuture，只在首帧 `??=` 懒加载一次，父 setState 不会让它
    // 重跑（本 State 存活、future 非 null）。这里显式监听刷新信号重载映射，使后台
    // 合集同步落库后书架立即成组（否则合集不渲染，直到重启 app）。
    mediaType.tabRefreshNotifier.addListener(_reloadShelfMapsOnTabRefresh);
    // BUG-992：顶层 tab IndexedStack 保活（BUG-750）后，切回书架不再隐式重拉远端书 →
    // 远端占位卡 + 书库概览总数要等用户手动下拉刷新才补齐。监听全局 tab 信号，切回
    // 书架 tab 时自动重拉一次远端（缓存 _lastRemoteState 顶住 waiting、不闪屏）。
    homeShellTabNotifier.addListener(_onShellTabActivated);
  }

  /// 切回书架 tab 时自动重拉远端书（BUG-992）。非书架 tab 的切换忽略。
  void _onShellTabActivated() {
    if (!mounted) return;
    if (homeShellTabNotifier.value == HomeTab.books) {
      _refreshRemoteBooks();
    }
  }

  /// tabRefreshNotifier 回调：重载书架合集折叠映射。后台合集同步（仅
  /// collectionsUpdated>0）现也触发 refreshTab（[AppModel.refreshAfterSyncRun]），
  /// 落到这里重载 _shelfMapsFuture，让新同步进来的合集成员立即成组。
  void _reloadShelfMapsOnTabRefresh() {
    if (!mounted) return;
    setState(() {
      _shelfMapsFuture = _loadShelfMaps();
    });
  }

  @override
  void dispose() {
    mediaType.tabRefreshNotifier.removeListener(_reloadShelfMapsOnTabRefresh);
    homeShellTabNotifier.removeListener(_onShellTabActivated);
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
    // BUG-940：合集标签维度（含全部选中标签的合集 id；null=无选中标签不过滤）。成员
    // 级标签过滤须并入此维度，否则「合集打了标签但成员没打」时成员被剥光、折叠不出
    // 合集组，合集永远筛不出来。
    final Set<int>? tagCollectionFilter =
        ref.watch(filteredCollectionIdsProvider).valueOrNull;
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
                // 下拉同步可能跑几十秒，光一个转圈看不出进展；没同步在飞时零高度。
                const SyncProgressBanner(),
                Expanded(
                  child: books.when(
                    data: (bookList) {
                      _batchAudiobookInfoFuture ??= _loadAllAudiobookInfo();
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
                          if (key == null) return false;
                          // BUG-940：成员命中标签、或所属合集命中标签都保留（后者让
                          // 打了标签的合集其成员整组存活，折叠出合集组）。
                          return keepMemberUnderTagFilter(
                            memberMatched: filterSet.contains(key),
                            primaryCollectionId:
                                _primaryCollectionByEntry['epub|$key'],
                            collectionFilter: tagCollectionFilter,
                          );
                        }).toList();
                      }
                      return FutureBuilder<Map<String, _AudiobookInfo>>(
                        future: _batchAudiobookInfoFuture,
                        builder: (context, abSnapshot) =>
                            FutureBuilder<_RemoteBookState?>(
                          future: _remoteBooksFuture,
                          builder: (context, remoteSnapshot) =>
                              FutureBuilder<void>(
                            future: _shelfMapsFuture,
                            builder: (context, _) =>
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
      adaptivePageRoute(
        context: context,
        builder: (_) => const CollectionsPage(),
      ),
    );
  }

  void _openReadingStatistics() {
    Navigator.push(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => const ReadingStatisticsPage(),
      ),
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
    // BUG-959: 一次 getAllCollectionItems 查全部成员内存分组，替代逐合集
    // getCollectionItems 的 N+1（合集越多首屏合集行渲染越慢）。判据
    // `primaryMap[key] == m.collectionId` 与旧逐合集 `== c.id` 等价。
    final Map<String, int> memberSortIndex = <String, int>{};
    for (final MediaCollectionItemRow m
        in await appModel.database.getAllCollectionItems()) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primaryMap[key] == m.collectionId) memberSortIndex[key] = m.sortIndex;
    }
    final List<EpubBookRow> epubRows =
        await appModel.database.getAllEpubBooks();
    _epubImportedAtByKey = <String, int>{
      for (final EpubBookRow r in epubRows) r.bookKey: r.importedAt,
    };
    _completedBookKeys = await appModel.database.getCompletedEpubBookKeys();
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
        s.srt?.title ??
        s.epub?.title ??
        s.remote?.title ??
        s.remoteSrt?.title ??
        '';
    int recentOf(CollectionOrderingItem<_ShelfBookSlot> it) {
      // 远端占位卡（EPUB 或纯 SRT）无本地阅读进度：退化到注入时编码的目录序（负
      // importedAt），稳定排在本地条目之后（详见 [_ShelfBookSlot.remote]）。
      if (it.payload.remote != null || it.payload.remoteSrt != null) {
        return it.importedAt;
      }
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

  /// 把标签拖到书架合集行头 = 给整个合集打标签（`CollectionShelfRow.onTagDropped`）。
  /// 不复用 [_addTagToMedia]：它的「已存在」提示固定是 `tag_already_on_book`，对合集
  /// 文案不对。`addTagToCollection` 幂等，这里先查现有标签给合集专属提示，成功后失效
  /// [filteredCollectionIdsProvider] 让标签过滤下合集卡显隐立即刷新。
  Future<void> _addTagToCollection(int collectionId, BookTagRow tag) async {
    final HibikiDatabase db = ref.read(appProvider).database;
    final List<BookTagRow> existing =
        await db.getTagsForCollection(collectionId);
    if (existing.any((BookTagRow t) => t.id == tag.id)) {
      HibikiToast.show(msg: t.tag_already_on_collection(name: tag.name));
      return;
    }
    await db.addTagToCollection(collectionId, tag.id);
    ref.invalidate(collectionTagMapProvider);
    ref.invalidate(filteredCollectionIdsProvider);
    if (mounted) {
      HibikiToast.show(msg: t.tag_added_to_collection(name: tag.name));
    }
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
  /// 数据边界（诚实外显）：hero = 在读（0<position<duration）EPUB-backed 书中
  /// 「最后阅读时间」（[bookLastReadAtProvider]，即 reader_positions.updatedAt）
  /// 最新者，显示「已读 x%」；无候选整块隐藏。BUG-777：旧实现取列表第一本
  /// 在读书，但列表序 = getAllEpubBooks 的 importedAt 倒序，选中的是「最近导入」
  /// 而非「最近阅读」的书。
  ///
  /// BUG-804：[progressBooks] 必须是**未按 srt 过滤的全量 EPUB-backed 列表**
  /// （`hibikiBooksProvider` 全部行，含有声书——EPUB 正文 + SRT 字幕同 bookKey）。
  /// 旧实现只喂 srt 过滤后的 `epubBooks`，有声书虽有进度与 lastReadAt 却被整类
  /// 排除，读了有声书回书架「继续阅读」永不更新。过滤到纯 EPUB 只为主网格卡
  /// 去重（有声书渲染成 SRT 卡），与 hero 无关。
  ///
  /// 原并排的「统计」三格（总数/在读/已完成，BUG-991 的口径修正随之退役）已按
  /// 用户反馈移除——与右上角「阅读统计」入口重复。
  Widget _buildShelfOverviewSection(List<MediaItem> progressBooks) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ShelfProgressTally<MediaItem> tally = tallyShelfProgress<MediaItem>(
      progressBooks,
      (MediaItem item) => item.position,
      (MediaItem item) => item.duration,
    );
    final MediaItem? hero = mostRecentlyReadCandidate(
      tally.inProgress,
      (MediaItem item) =>
          _lastReadAtByBookKey[_parseBookKey(item.mediaIdentifier)] ?? 0,
    );
    if (hero == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        0,
      ),
      child: _buildContinueReadingHero(hero, tokens),
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
                  // BUG-1086：与同卡封面（getDisplayThumbnailFromMediaItem）同源，
                  // 经 getDisplayTitleFromMediaItem 应用编辑弹窗写入的 override
                  // 书名；直读 DB 原始列 hero.title 会在改名后仍显示旧名。
                  mediaSource.getDisplayTitleFromMediaItem(hero),
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

  Widget _buildBodyWithSrtBooks(
    List<MediaItem> books,
    List<SrtBook> allSrtBooks,
    AsyncSnapshot<_RemoteBookState?>? remoteSnapshot,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // BUG-963：这三张「从 EPUB 借用」的展示映射（封面 / 有 EPUB 背书门控 / 借用进度）
    // 必须以**未筛选的全量 EpubBooks 行**为源，而不是筛选后的 `books`。标签筛选只裁剪
    // 参与网格展示的列表；合集内只打了标签的有声书（SRT）成员会向其关联 EPUB 借封面 /
    // 进度 / 「查看插画」门控，若以筛选子集构建，关联 EPUB 未命中同一标签即被筛掉 → 借不到
    // → 合集成员丢封面（BUG-937 让被筛合集能带命中成员显示后暴露此缺陷）。此处已 watch
    // 于上层 build（filteredBookIdsProvider 之上的 hibikiBooksProvider），read 全量安全。
    final List<MediaItem> allEpubBooksForBorrow =
        ref.read(hibikiBooksProvider(appModel.targetLanguage)).valueOrNull ??
            books;
    final Map<String, String> epubCoverUrisByBookKey = {};
    // TODO-1191：`allEpubBooksForBorrow` 是 hibikiBooksProvider 的全部 EpubBooks 行；
    // 解析出的 bookKey 全集即「有 EpubBooks 行」的真值，供 SRT 卡「查看插画」门控用。
    final Set<String> epubBackedBookKeys = {};
    // BUG-728：过滤前先收 EPUB 卡已算好的进度，供只以 SRT 卡出现的有声书复用。
    final Map<String, ({int position, int duration})> epubProgressByBookKey =
        {};
    for (final MediaItem item in allEpubBooksForBorrow) {
      final String? key = _parseBookKey(item.mediaIdentifier);
      if (key != null) {
        epubBackedBookKeys.add(key);
        epubProgressByBookKey[key] =
            (position: item.position, duration: item.duration);
      }
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
    // BUG-940：合集标签维度（含全部选中标签的合集 id）。srt 成员级过滤与末尾的
    // 合集组保留（[shelfGroups.removeWhere]）共用此集，避免「合集打了标签但成员没打」
    // 时 srt 成员被剥光、折叠不出合集组。
    final Set<int>? collectionFilter =
        ref.watch(filteredCollectionIdsProvider).valueOrNull;
    final List<SrtBook> srtBooks;
    if (srtFilterSet != null) {
      srtBooks = allSrtBooks
          .where((b) =>
              b.id != null &&
              keepMemberUnderTagFilter(
                memberMatched: srtFilterSet.contains(b.id),
                primaryCollectionId: _primaryCollectionByEntry['srt|${b.uid}'],
                collectionFilter: collectionFilter,
              ))
          .toList();
    } else if (hasActiveFilter) {
      srtBooks = const [];
    } else {
      srtBooks = allSrtBooks;
    }
    // 视频归「视频」tab（HomeVideoPage）独占，书架不再显示视频分区（用户反馈：
    // 书架是书的地方）。已导入视频只在视频 tab 呈现；书架拖入视频仍可导入（经
    // _handleShelfDrop → VideoImportDialog），落库后同样只在视频 tab 可见。
    _visibleEpubBooks = epubBooks;
    _visibleSrtBooks = srtBooks;
    // 多端库联合视图（spec 2026-07-12 §2.1/§2.4/§2.5）：把「远端有、本地无」的书
    // 混排成主网格占位卡。远端目录拉取失败/未配对/无后端（remoteState==null 或
    // failed）→ 占位卡不出现（离线=只剩本地）；「显示远端条目」开关关闭 → 同样不
    // 渲染；标签筛选激活时占位卡不参与（远端书无本地标签），只在无筛选时混排。
    // BUG-992：自动刷新（切回书架重拉远端）期间 future 切成 waiting → data 暂为 null。
    // 缓存上次成功的远端态、waiting 时沿用，避免每次切回远端占位卡 + 书库概览总数闪一
    // 下（仿视频页 _videosCache）。失败态不覆盖缓存（离线时下一次 waiting 仍能顶住旧数据）。
    final _RemoteBookState? snapState = remoteSnapshot?.data;
    if (snapState != null && !snapState.failed) {
      _lastRemoteState = snapState;
    }
    final _RemoteBookState? remoteState = snapState ?? _lastRemoteState;
    final bool showRemote = remoteState != null &&
        !remoteState.failed &&
        !hasActiveFilter &&
        appModel.prefsRepo.showRemoteEntries;
    final List<RemoteBookInfo> remoteBooks =
        showRemote ? remoteState.books : const <RemoteBookInfo>[];
    // 纯 SRT（standalone）远端有声书占位（互联后端 listRemoteAudiobooks 的 standalone
    // 项，本地无同 uid SrtBook）——与远端 EPUB 书同门控混排进主网格。
    final List<RemoteAudiobookInfo> remoteSrtBooks =
        showRemote ? remoteState.srtAudiobooks : const <RemoteAudiobookInfo>[];
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
    // 纯 SRT 远端有声书占位混入：mediaType='srt' + entryKey=uid，与本地 SRT 成员及
    // 已同步的合集成员（entryKey=uid）**同键**，故经现有 _primaryCollectionByEntry 就能
    // 折进合集（无需 epub 那样的 downloadId≠bookKey 回填）。importedAt 负值排本地之后。
    for (int i = 0; i < remoteSrtBooks.length; i++) {
      shelfItems.add(
        CollectionOrderingItem<_ShelfBookSlot>(
          mediaType: 'srt',
          entryKey: remoteSrtBooks[i].identity,
          importedAt: -1 - remoteBooks.length - i,
          payload: _ShelfBookSlot(remoteSrt: remoteSrtBooks[i]),
        ),
      );
    }
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
      final String key = 'epub|${book.downloadId}';
      final RemoteCollectionMembership? membership = book.collection;
      if (membership != null) {
        // 互联/host 路径：host 下发 RemoteBookInfo.collection，按 (name,type) 解析
        // 本地合集 id 注入折叠归属。
        final int? cid = _resolveLocalCollectionId(
          membership.collectionName,
          membership.collectionType,
        );
        if (cid == null) continue; // 归属解析不到本地合集 → 散卡降级
        primaryByEntry[key] = cid;
        memberSortIndex[key] = membership.sortIndex;
        continue;
      }
      // 云盘后端（CloudRemoteBookClient）没有 host 实时库 API，不下发 collection
      // 字段。但合集成员已由 collection_sync_engine 落进本地 MediaCollectionItems
      // （entryKey = 本地 bookKey = sanitizeTtuFilename(title)）。远端占位卡的 title
      // 与本地书同名，故用其本地等价 bookKey 回查已同步的折叠归属注入——云盘远端书
      // 也能折进对应合集行（否则云盘合集永远不成组，BUG：云盘书架合集不渲染）。
      final String localKey = 'epub|${sanitizeTtuFilename(book.title)}';
      final int? cid = _primaryCollectionByEntry[localKey];
      if (cid == null) continue; // 本地无已同步的合集归属 → 散卡降级
      primaryByEntry[key] = cid;
      final int? sidx = _memberSortIndex[localKey];
      if (sidx != null) memberSortIndex[key] = sidx;
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
    // 合集标签过滤：含【全部】选中标签的合集 id（null = 无选中标签，不过滤）。被标签
    // 过滤隐藏的合集连同成员从 shelfGroups 移除（成员随合集隐藏，符合按合集标签显隐
    // 语义）；散书由 filteredBookIdsProvider / filteredSrtBookIdsProvider 另行过滤。
    // collectionFilter 已在 srt 过滤前读取（BUG-940 成员救回共用同一集）。
    if (collectionFilter != null) {
      shelfGroups.removeWhere((CollectionGroup<_ShelfBookSlot> g) =>
          g.collection != null && !collectionFilter.contains(g.collection!.id));
    }
    // 块2：记录本帧渲染成横排行的合集 id（供全选/反选把可见合集纳入整选集）。
    _visibleCollectionIds = <int>[
      for (final CollectionGroup<_ShelfBookSlot> g in shelfGroups)
        if (g.collection != null) g.collection!.id,
    ];
    _epubCoverUrisByBookKey = epubCoverUrisByBookKey;
    _epubBackedBookKeys = epubBackedBookKeys;
    _epubProgressByBookKey = epubProgressByBookKey;
    // BUG-1008：空态判定看**全部**会渲染成卡的列表（含纯 SRT 远端占位）。标签筛选
    // 激活时才可能落到 tag_no_books_for_filter；旧实现另有一个
    // `hasActiveFilter && epubBooks.isEmpty` 特殊分支——SRT 命中已渲染网格却仍
    // 无条件叠「无匹配」空态文案，且丢 RefreshIndicator / 合集横排行 / 书库概览。
    // 筛选态与常态统一走下方主分支组装（shelfGroups 已能承载纯 SRT 命中结果），
    // 特殊分支消灭。
    if (epubBooks.isEmpty &&
        srtBooks.isEmpty &&
        remoteBooks.isEmpty &&
        remoteSrtBooks.isEmpty) {
      return hasActiveFilter
          ? Center(
              child: HibikiPlaceholderMessage(
                icon: Icons.filter_list_off,
                message: t.tag_no_books_for_filter,
              ),
            )
          : buildPlaceholder();
    }
    return RawScrollbar(
      thumbVisibility: true,
      thickness: 3,
      controller: mediaType.scrollController,
      child: LayoutBuilder(
        // 下拉刷新：保活后切回书架不再隐式重拉远端，给用户显式强制刷新入口。
        builder: (context, constraints) => RefreshIndicator(
          onRefresh: _pullToRefreshBooks,
          child: CustomScrollView(
            controller: mediaType.scrollController,
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.gap)),
              // 书架顶部「继续阅读 hero」条。原并排的「统计」三格（总数/在读/
              // 已完成）按用户反馈移除——右上角「阅读统计」已有完整入口，此处
              // 属重复信息。无在读候选时整条隐藏。
              // BUG-804：hero 喂**未过滤的全量 EPUB-backed `books`**（含有声书），
              // 不是 srt 过滤后的 `epubBooks`——否则读了有声书「继续阅读」永不更新。
              if (epubBooks.isNotEmpty || srtBooks.isNotEmpty)
                SliverToBoxAdapter(
                  child: _buildShelfOverviewSection(books),
                ),
              // TODO-902: 书架不再按类型分区（删 srt_books_section / section_epub
              // 两个分区头），SRT 有声书卡与 EPUB 卡混排进同一网格（SRT 在前、EPUB
              // 在后，沿用各自现有顺序，卡片本身的类型标识保留）。视频不再进书架
              // （归「视频」tab 独占）。
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
            ],
          ),
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
    // 行头计数 = 行体实际渲染的成员数（本地 + 远端占位），与 itemCount 同源（BUG-790
    // 书籍侧对齐；视频合集 home_video_page 已修，书架合集此前漏跟）。旧口径只数本地成员，
    // 导致「远端书已折进本地合集」时行头数字比眼前卡片少（甚至全为未下载远端书时显示
    // 「0 本」），与所见割裂（用户实报）。行头数字必须诚实反映该行看得见的卡片数。
    final int memberCount = group.items.length;
    return Padding(
      // 水平不加 padding：书卡自带 12px 内边距，与网格散卡左缘逐像素对齐。
      padding: EdgeInsets.symmetric(
        vertical: tokens.spacing.gap / 2,
      ),
      child: CollectionShelfRow(
        key: ValueKey<String>('reader_shelf_collection_row_${collection.id}'),
        title: collection.name,
        countLabel: t.series_item_count(n: memberCount),
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
        // 拖标签到行头 = 给整个合集打标签（与散书书级拖放一致）。
        onTagDropped: (BookTagRow tag) =>
            _addTagToCollection(collection.id, tag),
        // 行头下方展示该合集已打的标签 chip（与散书标签列同形）。
        tags: ref.watch(collectionTagMapProvider).valueOrNull?[collection.id],
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
    // 远端占位卡（EPUB / 纯 SRT）现可折进合集（经已同步的合集成员归属），成员卡也要
    // 分派到远端占位渲染，否则命中下面的 epub! 空断言。
    final RemoteBookInfo? remote = slot.remote;
    if (remote != null) return _buildRemoteBookCard(remote);
    final RemoteAudiobookInfo? remoteSrt = slot.remoteSrt;
    if (remoteSrt != null) return _buildRemoteSrtCard(remoteSrt);
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
      final RemoteAudiobookInfo? remoteSrt = slot.remoteSrt;
      if (remoteSrt != null) {
        return _buildRemoteSrtCard(remoteSrt);
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
    // 远端占位卡的堆叠封面：EPUB 用远端封面，纯 SRT 用占位图标（无远端封面来源）。
    final RemoteBookInfo? remote = slot.remote;
    if (remote != null) return _buildRemoteBookCover(remote);
    if (slot.remoteSrt != null) {
      return _coverPlaceholderIcon(Icons.headphones_outlined);
    }
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
        context: context,
        builder: (_) => MediaCollectionGridDetailPage(
          database: appModel.database,
          collection: collection,
          memberCardBuilder: _buildCollectionMemberCard,
          onOpenMember: _openCollectionMember,
          onChanged: () {
            _shelfMapsFuture = _loadShelfMaps();
            if (mounted) setState(() {});
          },
          onDeleteMembersMedia: _deleteCollectionMembersMedia,
        ),
      ),
    );
  }

  /// 「删除合集」时连同成员本体一起删：按 (mediaType, entryKey) 分派到删书/删视频。
  /// 复用批量删除同一分派纪律（[_batchDeleteConfirm]）——epub 直接删；srt 先 findByUid
  /// 拿 bookKey 删本体再删 srt 行；video 逐个删并末尾一次 compact。删书本身各自 VACUUM。
  Future<void> _deleteCollectionMembersMedia(
    List<MediaCollectionItemRow> members,
  ) async {
    bool anyVideo = false;
    for (final MediaCollectionItemRow m in members) {
      switch (m.mediaType) {
        case 'epub':
          await ReaderHibikiSource.instance.deleteBook(
            db: appModel.database,
            bookKey: m.entryKey,
            appModel: appModel,
          );
        case 'srt':
          final SrtBookRepository repo = SrtBookRepository(appModel.database);
          final SrtBook? book = await repo.findByUid(m.entryKey);
          if (book != null) {
            if (book.bookKey.isNotEmpty) {
              await ReaderHibikiSource.instance.deleteBook(
                db: appModel.database,
                bookKey: book.bookKey,
                appModel: appModel,
              );
            }
            await repo.delete(m.entryKey);
          }
        case 'video':
          // 混合合集里若混入视频成员：删视频 DB 行 + app 拥有副本，保留原始视频文件。
          await _videoRepo.deleteVideoBookAndReclaimAssets(
            m.entryKey,
            compactDatabase: false,
          );
          anyVideo = true;
        case 'game':
          // 游戏成员**刻意跳过**：game 维度只支持解散合集不删本体——游戏本体是
          // 用户安装目录（exe 及其资源），绝不能从合集删除路径连带删除；从库移除
          // 走游戏库页自己的「移除」。合集引用行随后由 deleteMediaCollection
          // cascade 清理，游戏回到游戏库散卡。
          break;
      }
    }
    if (anyVideo) {
      await _videoRepo.compactAfterVideoDeleteBestEffort();
    }
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
    // BUG-1009：详情页与书架是两条同时存活的路由（详情页 push 在书架之上），成员卡
    // 若复用书架同名 focusId，两个 HibikiFocusTarget 撞号——焦点注册表按 id 覆盖，
    // 后注册者赢、pop 后书架卡失焦。详情页渲染路径统一加 route 前缀隔离命名空间。
    const String prefix = 'collection-detail-';
    if (mediaType == 'srt') {
      for (final SrtBook book in _visibleSrtBooks) {
        if (book.uid == entryKey) {
          return _buildSrtCard(
            book,
            epubCoverUri: _epubCoverUrisByBookKey[book.bookKey],
            removeFromCollection: onRemoveFromCollection,
            focusIdPrefix: prefix,
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
            focusIdPrefix: prefix,
          );
        }
      }
      return null;
    }
    // 其它 mediaType（'video' / 'game' / 未来新增）：本页不认识 → 返 null 由详情页
    // 跳过，不当成 epub 渲染。混合合集的 game 成员在游戏库页打开同一合集时渲染。
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

  /// 弹删除确认框，返回用户选择的删除范围（[DeleteScope.syncEverywhere] = 同步删除到
  /// 其他设备 / [DeleteScope.keepLocalOnly] = 仅本机）；取消或已 unmount 返回 null。
  Future<DeleteScope?> _confirmMediaDelete({
    required String title,
    required String message,
  }) async {
    final DeleteScope? scope = await showAppDialog<DeleteScope>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: title,
        message: message,
        onConfirm: (DeleteScope s) => Navigator.pop(ctx, s),
      ),
    );
    if (!mounted) return null;
    return scope;
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
      metadata: _progressBar(
        item,
        completed: bookKey != null && _completedBookKeys.contains(bookKey),
      ),
      // BUG-990：这本书的有声书包还在下载 → 本地 EPUB 卡继续显示加载覆盖层。
      loadingOverlay: _audiobookDownloadingOverlay(bookKey),
    );
  }

  @override
  Widget buildMediaItem(MediaItem item) =>
      _buildEpubBookCard(item, selectable: true);

  /// EPUB 书卡渲染。[selectable]（默认经 [buildMediaItem] 传 true）= 多选态可单独勾选；
  /// 块2：合集行成员卡传 false（selectionKey 置空 → 不画勾、不可单独勾）。
  /// [removeFromCollection] 非空（合集详情页成员卡）时给长按 / 右键对话框补一条
  /// 「移出合集」动作，让键盘/手柄用户（聚焦长按 A 弹此对话框，不经网格指针菜单）也能移出。
  /// [focusIdPrefix]：详情页渲染路径传 'collection-detail-' 隔离焦点 id 命名空间
  /// （BUG-1009，见 [_buildCollectionMemberCard]）；书架路径恒空串（id 不变）。
  Widget _buildEpubBookCard(MediaItem item,
      {bool selectable = true,
      VoidCallback? removeFromCollection,
      String focusIdPrefix = ''}) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    final Widget card = _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('book_entry_${item.mediaIdentifier}'),
      focusId: HibikiFocusId(
          '${focusIdPrefix}reader-shelf-book-${item.mediaIdentifier}'),
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
                      // 合集详情页成员卡语境：隐藏「加入合集」（同一条目在详情页
                      // 语境下再加合集没有意义），只补「移出合集」。
                      ..._epubExtraActions(it, inCollectionDetail: true),
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
    return _epubExtraActions(item);
  }

  /// EPUB 书卡长按菜单动作真身。[inCollectionDetail] = 合集详情页成员卡语境
  /// （菜单已注入「移出合集」）——该语境下隐藏「加入合集」，同一条目在详情页
  /// 语境下再加合集没有意义。
  List<DialogAction> _epubExtraActions(MediaItem item,
      {bool inCollectionDetail = false}) {
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
        label: _completedBookKeys.contains(bookKey)
            ? t.book_mark_uncompleted_action
            : t.book_mark_completed_action,
        icon: _completedBookKeys.contains(bookKey)
            ? Icons.check_circle
            : Icons.check_circle_outline,
        onPressed: () => _toggleBookCompleted(bookKey),
      ),
      // 单卡「加入合集」：与批量三档共用同一 DAO 路径；entryKey 编码与
      // shelfSelectionToEntry 对 epub 选择键的解码一致（= bookKey）。
      if (!inCollectionDetail)
        DialogListAction(
          label: t.add_to_collection,
          icon: Icons.collections_bookmark_outlined,
          onPressed: () => _addEpubToCollection(item, bookKey),
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

  /// 单卡「加入合集」（EPUB 卡菜单入口）：先收起长按菜单，再弹共享的合集选择
  /// 弹窗（新建合集默认名 = 该书标题剥卷号，与批量档1同款推导）；加入成功后按
  /// [_combineAddToExisting] 同款刷新（重取分组映射 + 重绘）。
  Future<void> _addEpubToCollection(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final bool added = await showAddToCollectionDialog(
      context: context,
      database: appModel.database,
      mediaType: 'epub',
      entryKey: bookKey,
      // P4：用户看到的默认合集名应是改名后的显示名（身份 entryKey 仍是 raw
      // bookKey，不受影响）。
      defaultNewName: deriveSeriesDefaultName(
        <String>[displayTitleForBook(item: item, rawTitle: item.title)],
        fallback: t.series_default_name,
      ),
    );
    if (!added || !mounted) return;
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
  }

  /// 手动切换书 / 有声书「已读完」状态：写 EpubBooks.completedAt（单一真值，按
  /// bookKey），有声书 SRT 卡也调它（传其配对 bookKey）。已完成 → 清除；未完成 →
  /// 置当前时间。切换后重取完成集合并重绘，概览统计与卡片视觉下一帧即同步。
  /// [bookKey] 为空（无 EPUB 正文的纯字幕书）时静默忽略——该书无进度维度、也无
  /// 完成真值载体，与 [_openSrtBook] 的 `srt_epub_not_ready` 门控一致。
  Future<void> _toggleBookCompleted(String bookKey) async {
    Navigator.pop(context);
    if (bookKey.isEmpty) return;
    final bool wasCompleted = _completedBookKeys.contains(bookKey);
    await appModel.database.setEpubBookCompleted(
      bookKey,
      wasCompleted ? null : DateTime.now(),
    );
    if (!mounted) return;
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
    HibikiToast.show(
      msg: wasCompleted ? t.book_marked_uncompleted : t.book_marked_completed,
    );
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
    this.remoteSrt,
  });

  final SrtBook? srt;
  final MediaItem? epub;
  final RemoteBookInfo? remote;

  /// 纯 SRT（standalone）远端有声书占位卡（互联后端 listRemoteAudiobooks 的
  /// standalone 项，本地尚无同 uid 的 SrtBook）。与 [remote] 同为「远端占位」，无本地
  /// 阅读进度，排在本地条目之后；下载后原地变本地 SRT 卡。
  final RemoteAudiobookInfo? remoteSrt;
}
