import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

/// 浏览**已配对互联对端**的漫画库，与浏览一个扩展源同构。
///
/// 与书架上那条既有的「远端漫画」分区分工明确：那条是**下载**（把整卷搬过来再本地
/// 读），这一页是**源**（不下载，直接在对端上翻页）——正是 Suwayomi 作为 Tachiyomi
/// 源时的形态。两条路并存，用户按需选。
///
/// 清单不新开端点，走的还是 `/api/library/books` 里 `format=='manga'` 的那些行。
class InterconnectMangaBrowsePage extends ConsumerStatefulWidget {
  const InterconnectMangaBrowsePage({super.key, this.backend});

  /// 测试注入口；生产恒用单例。
  final InterconnectSyncBackend? backend;

  @override
  ConsumerState<InterconnectMangaBrowsePage> createState() =>
      _InterconnectMangaBrowsePageState();
}

class _InterconnectMangaBrowsePageState
    extends ConsumerState<InterconnectMangaBrowsePage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  late final InterconnectSyncBackend _backend =
      widget.backend ?? InterconnectSyncBackend.instance;
  List<RemoteBookInfo> _items = const <RemoteBookInfo>[];
  String _query = '';
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<RemoteBookInfo> items = await InterconnectMangaCatalog(
        _backend,
      ).listSeries();
      if (!mounted) return;
      final RemoteCollectionAdoptionService adoption =
          RemoteCollectionAdoptionService(ref.read(appProvider).database);
      await adoption.adoptBooks(items);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'InterconnectMangaBrowse.load',
        error,
        stack,
      );
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// 搜索在本端过滤已拉回的清单，不再往对端发请求：对端的书清单是一次性全量返回的
  /// （没有分页端点），再发一次只是把同一份数据重拉一遍。归一化走全应用统一的
  /// [matchesMediaSearch]，与书架/视频库的搜索口径一致。
  List<RemoteBookInfo> get _visible => filterByMediaSearch<RemoteBookInfo>(
        _items,
        _query,
        (RemoteBookInfo book) => <String>{book.displayName, book.title},
      );

  void _openSeries(RemoteBookInfo book) {
    final AppModel appModel = ref.read(appProvider);
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaSeriesPage(
          target: SourceMangaSeriesTarget(
            adapter: InterconnectLibraryAdapter(backend: _backend),
            service: OnlineMangaLibraryService(
              database: appModel.database,
              rootDirectory: appModel.interconnectMangaLibraryRoot,
              adapter: InterconnectLibraryAdapter(backend: _backend),
            ),
            seed: InterconnectMangaCatalog.entryFor(book),
            sourceLabel: t.audio_source_fushi_interconnect,
            remoteCoverBuilder: (BuildContext context) => _RemoteMangaCover(
              backend: _backend,
              book: book,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
        title: t.audio_source_fushi_interconnect,
        automaticallyImplyLeading: false,
        headerCompact: true,
        leading: BackButton(
          key: const ValueKey<String>('interconnect_manga_back'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        headerBottom: Padding(
          padding: const EdgeInsets.only(top: 8),
          // 2026-10 体验优化：统一为 FushiSearchField；本页边打边滤。
          child: FushiSearchField(
            fieldKey: const ValueKey<String>('interconnect_manga_search'),
            focusId: const FushiFocusId('interconnect-manga-search'),
            controller: _searchController,
            focusNode: _searchFocus,
            hintText: t.mihon_source_search,
            onChanged: (String value) => setState(() => _query = value),
            onSubmitted: (String value) => setState(() => _query = value),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
        ),
        body: _buildResults(),
      );

  Widget _buildResults() {
    if (_loading && _items.isEmpty) {
      return Center(child: adaptiveIndicator(context: context));
    }
    // 2026-10 体验优化：错误 / 空态统一 FushiPlaceholderMessage，重试统一
    // FilledButton.icon；错误文案经 describeOnlineSourceError 归一。
    final Object? error = _error;
    if (error != null && _items.isEmpty) {
      return FushiPlaceholderMessage(
        icon: Icons.error_outline,
        message: describeOnlineSourceError(error),
        action: FushiFilledButton.icon(
          key: const ValueKey<String>('interconnect_manga_retry'),
          onPressed: () => unawaited(_load()),
          icon: const FushiIcon(Icons.refresh_rounded),
          label: Text(t.retry),
        ),
      );
    }
    final List<RemoteBookInfo> visible = _visible;
    if (visible.isEmpty) {
      return FushiPlaceholderMessage(
        icon: Icons.search_off_outlined,
        message: t.mihon_source_no_results,
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return FushiRefreshIndicator(
          onRefresh: _load,
          child: FushiEntranceScope(
            child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: 0.62,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: visible.length,
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int index,
            ) {
              final RemoteBookInfo book = visible[index];
              return FushiCard(
                padding: EdgeInsets.zero,
                onTap: () => _openSeries(book),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: _RemoteMangaCover(backend: _backend, book: book),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        book.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
          ),
        );
      },
    );
  }
}

/// 对端封面。
///
/// 必须走 [RemoteCoverImage] 而不是 `Image.network`：自签证书的对端需要
/// `badCertificateCallback`，Flutter 内部那条 HttpClient 拿不到（BUG-569）。
class _RemoteMangaCover extends StatelessWidget {
  const _RemoteMangaCover({required this.backend, required this.book});

  final InterconnectSyncBackend backend;
  final RemoteBookInfo book;

  @override
  Widget build(BuildContext context) {
    final String? url = book.coverUrl;
    // 占位底跟随主题中性色：black12 在深色主题下几乎不可见。
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (url == null || url.isEmpty) {
      return ColoredBox(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: FushiIcon(
            Icons.menu_book_outlined,
            color: cs.onSurfaceVariant,
          ),
        ),
      );
    }
    return Image(
      image: RemoteCoverImage(url, backend, cacheKey: book.downloadId),
      fit: BoxFit.cover,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          ColoredBox(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: FushiIcon(
            Icons.broken_image_outlined,
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
