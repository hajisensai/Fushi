import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:fushi/utils.dart';

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
      for (final RemoteBookInfo book in items) {
        await adoption.adoptBook(book);
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on Object catch (error) {
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
          child: TextField(
            key: const ValueKey<String>('interconnect_manga_search'),
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t.mihon_source_search,
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: (String value) => setState(() => _query = value),
          ),
        ),
        body: _buildResults(),
      );

  Widget _buildResults() {
    if (_loading && _items.isEmpty) {
      return Center(child: adaptiveIndicator(context: context));
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(
                key: const ValueKey<String>('interconnect_manga_retry'),
                onPressed: () => unawaited(_load()),
                child: Text(t.retry),
              ),
            ],
          ),
        ),
      );
    }
    final List<RemoteBookInfo> visible = _visible;
    if (visible.isEmpty) {
      return Center(child: Text(t.mihon_source_no_results));
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return RefreshIndicator(
          onRefresh: _load,
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: 0.62,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: visible.length,
            itemBuilder: (BuildContext context, int index) {
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
            },
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
    if (url == null || url.isEmpty) {
      return const ColoredBox(
        color: Colors.black12,
        child: Center(child: Icon(Icons.menu_book_outlined)),
      );
    }
    return Image(
      image: RemoteCoverImage(url, backend, cacheKey: book.downloadId),
      fit: BoxFit.cover,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          const ColoredBox(
        color: Colors.black12,
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}
