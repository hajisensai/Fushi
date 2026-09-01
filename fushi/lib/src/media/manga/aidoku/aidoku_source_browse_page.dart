import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_reader_chapter.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// Catalog browser for one installed Aidoku source.
///
/// It deliberately follows the same page/header/search/grid shape as
/// `MihonSourceBrowsePage`; only the runtime adapter differs.
class AidokuSourceBrowsePage extends StatefulWidget {
  const AidokuSourceBrowsePage({
    required this.package,
    super.key,
    this.runtime,
  });

  final AidokuInstalledPackage package;
  final AidokuRuntime? runtime;

  @override
  State<AidokuSourceBrowsePage> createState() => _AidokuSourceBrowsePageState();
}

class _AidokuSourceBrowsePageState extends State<AidokuSourceBrowsePage> {
  final TextEditingController _searchController = TextEditingController();
  late final AidokuRuntime _runtime =
      widget.runtime ?? AidokuRuntimeFactory.create();
  List<AidokuListing> _listings = const <AidokuListing>[];
  AidokuListing? _listing;
  List<Map<String, Object?>> _items = const <Map<String, Object?>>[];
  bool _loading = true;
  bool _hasNextPage = false;
  bool _searching = false;
  int _page = 1;
  int _generation = 0;
  Object? _error;
  String? _sourceBaseUrl;

  @override
  void initState() {
    super.initState();
    unawaited(_initialise());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialise() async {
    try {
      final AidokuPackageInspection inspection =
          await _runtime.inspect(widget.package.packagePath);
      if (!mounted) return;
      _listings = inspection.listings;
      _sourceBaseUrl = (inspection.sourceInfo['urls'] as List<Object?>?)
          ?.map((Object? value) => value.toString())
          .where(
              (String value) => Uri.tryParse(value)?.isScheme('https') == true)
          .firstOrNull;
      _listing = _listings.firstOrNull;
      _searching = _listing == null;
      await _load(reset: true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && (_loading || !_hasNextPage)) return;
    final int generation = reset ? ++_generation : _generation;
    final int requestedPage = reset ? 1 : _page + 1;
    final bool searching = _searching;
    final AidokuListing? listing = _listing;
    final String query = _searchController.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, Object?> result = searching || listing == null
          ? await _runtime.search(
              widget.package.packagePath,
              query: query,
              page: requestedPage,
            )
          : await _runtime.browse(
              widget.package.packagePath,
              listing,
              page: requestedPage,
            );
      final List<Map<String, Object?>> entries = (result['entries']
                  as List<Object?>? ??
              const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> value) => value.cast<String, Object?>())
          .where((Map<String, Object?> value) =>
              (value['key']?.toString().isNotEmpty ?? false))
          .toList(growable: false);
      if (!mounted || generation != _generation) return;
      setState(() {
        final List<Map<String, Object?>> previous =
            reset ? const <Map<String, Object?>>[] : _items;
        final Set<String> seen = previous
            .map((Map<String, Object?> item) => item['key'].toString())
            .toSet();
        final List<Map<String, Object?>> additions = entries
            .where(
                (Map<String, Object?> item) => seen.add(item['key'].toString()))
            .toList(growable: false);
        _items = <Map<String, Object?>>[...previous, ...additions];
        _page = requestedPage;
        _hasNextPage = result['has_next_page'] == true &&
            entries.isNotEmpty &&
            (reset || additions.isNotEmpty);
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error;
      });
      if (_items.isNotEmpty) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  void _search() {
    _searching = true;
    unawaited(_load(reset: true));
  }

  void _selectListing(AidokuListing listing) {
    _listing = listing;
    _searching = false;
    unawaited(_load(reset: true));
  }

  void _openDetails(Map<String, Object?> manga) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => AidokuMangaDetailPage(
          package: widget.package,
          runtime: _runtime,
          manga: manga,
          sourceBaseUrl: _sourceBaseUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
        title: widget.package.name,
        automaticallyImplyLeading: false,
        headerCompact: true,
        leading: BackButton(
          key: const ValueKey<String>('aidoku_source_back'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: <Widget>[
          if (_listings.isNotEmpty)
            DropdownButton<AidokuListing>(
              key: const ValueKey<String>('aidoku_source_listing'),
              value: _searching ? null : _listing,
              hint: Text(t.mihon_source_search),
              items: <DropdownMenuItem<AidokuListing>>[
                for (final AidokuListing listing in _listings)
                  DropdownMenuItem<AidokuListing>(
                    value: listing,
                    child: Text(listing.name),
                  ),
              ],
              onChanged: (AidokuListing? value) {
                if (value != null) _selectListing(value);
              },
            ),
        ],
        headerBottom: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            key: const ValueKey<String>('aidoku_source_search'),
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t.mihon_source_search,
              prefixIcon: const Icon(Icons.search),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        body: Column(
          children: <Widget>[
            Expanded(child: _buildResults()),
          ],
        ),
      );

  Widget _buildResults() {
    if (_loading && _items.isEmpty) {
      return Center(child: adaptiveIndicator(context: context));
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(aidokuErrorMessage(_error), textAlign: TextAlign.center),
        ),
      );
    }
    if (_items.isEmpty) return Center(child: Text(t.mihon_source_no_results));
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: 0.62,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: _items.length + (_hasNextPage ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index == _items.length) {
              return Center(
                child: _loading
                    ? adaptiveIndicator(context: context)
                    : IconButton(
                        onPressed: () => unawaited(_load(reset: false)),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
              );
            }
            final Map<String, Object?> manga = _items[index];
            return FushiCard(
              padding: EdgeInsets.zero,
              onTap: () => _openDetails(manga),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: _AidokuCover(
                      url: manga['cover']?.toString(),
                      referer: _sourceBaseUrl,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      manga['title']?.toString() ?? manga['key'].toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 源浏览里的作品页入口。
///
/// v88 前这里是个**瞬时**详情页：章节列表只活在 widget state 里，页面 pop 即丢；
/// `aidoku/` 全目录一处 `insertEpubBook` 都没有，所以 Aidoku 的作品根本进不了
/// 书架，读进度也无处可落。
///
/// 现在它只把 Aidoku 的包/作品翻译成运行时无关的 seed，页面本体交给
/// [MangaSeriesPage] —— 加入书架、每章已读、断点续读从此与 Mihon 同一套。
class AidokuMangaDetailPage extends ConsumerWidget {
  const AidokuMangaDetailPage({
    required this.package,
    required this.runtime,
    required this.manga,
    required this.sourceBaseUrl,
    super.key,
  });

  final AidokuInstalledPackage package;
  final AidokuRuntime runtime;
  final Map<String, Object?> manga;
  final String? sourceBaseUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 拿不到 AppModel 是**正常状态**，不是错误：这一页展示所需的一切都在
    // adapter 里，AppModel 只决定「能不能加入书架」。硬读会让这一页在没有
    // ProviderScope 的树里直接崩（widget 测试正是这么立起来的）。
    AppModel? appModel;
    try {
      appModel = ref.read(appProvider);
    } on Object {
      appModel = null;
    }
    return MangaSeriesPage(
      target: SourceMangaSeriesTarget(
        // 包与 runtime 都已在手：预置进去，别让作品页再去扫一遍已安装包列表。
        adapter: AidokuLibraryAdapter(
          runtime: runtime,
          presetPackage: package,
        ),
        // 刻意不走 AppModel.onlineMangaLibraryService：那条分派恒用
        // AidokuRuntimeFactory.create()，会把这里注入的 runtime（测试替身、
        // 或浏览页已经建好的那一份）丢掉。拿不到 AppModel 时留空——展示照旧，
        // 只是不能入库。
        service: appModel == null
            ? null
            : OnlineMangaLibraryService(
                database: appModel.database,
                rootDirectory: appModel.aidokuLibraryRoot,
                adapter: AidokuLibraryAdapter(
                  runtime: runtime,
                  presetPackage: package,
                ),
              ),
        seed: OnlineMangaLibraryEntry(
          runtime: OnlineMangaRuntimeKind.aidoku,
          // Aidoku 是单源包：包 id 同时充当扩展身份和源身份。
          extensionPackage: package.id,
          sourceId: package.id,
          series: AidokuLibraryAdapter.seriesOf(
            manga,
            fallbackKey: manga['key']?.toString() ?? '',
          ),
          // 网格上只有标题和封面；章节由作品页进页后自己拉。
          chapters: const <OnlineMangaChapter>[],
        ),
        sourceLabel: package.name,
        remoteCoverBuilder: (BuildContext context) => _AidokuCover(
          url: manga['cover']?.toString(),
          referer: _aidokuHttpsUrl(manga['url']) ?? sourceBaseUrl,
        ),
      ),
    );
  }
}

class _AidokuChapterReaderPage extends StatefulWidget {
  const _AidokuChapterReaderPage({
    required this.package,
    required this.runtime,
    required this.manga,
    required this.chapter,
  });

  final AidokuInstalledPackage package;
  final AidokuRuntime runtime;
  final Map<String, Object?> manga;
  final Map<String, Object?> chapter;

  @override
  State<_AidokuChapterReaderPage> createState() =>
      _AidokuChapterReaderPageState();
}

class _AidokuChapterReaderPageState extends State<_AidokuChapterReaderPage> {
  AidokuReaderChapter? _resolved;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<Object?> result = await widget.runtime.getPages(
        widget.package.packagePath,
        widget.manga,
        widget.chapter,
      );
      final List<AidokuImagePage> pages = result
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> value) =>
              AidokuImagePage.fromJson(value.cast<String, Object?>()))
          .toList(growable: false);
      if (pages.isEmpty) {
        throw const AidokuRuntimeException(
          'EMPTY_CHAPTER',
          'Aidoku returned no readable image pages for this chapter',
        );
      }
      if (mounted) {
        setState(() {
          _resolved = AidokuReaderChapter(
            package: widget.package,
            manga: widget.manga,
            chapter: widget.chapter,
            pages: pages,
          );
        });
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'AidokuReader.pages ${widget.package.id} ${widget.chapter['key']}',
        error,
        stack,
      );
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String chapterTitle = aidokuChapterDisplayTitle(widget.chapter);
    final AidokuReaderChapter? resolved = _resolved;
    if (resolved != null) {
      final String identity = <String>[
        widget.package.id,
        widget.manga['key']?.toString() ?? '',
        widget.chapter['key']?.toString() ?? '',
      ].join('\u001f');
      return FushiAppUiScaleNeutralizer(
        child: MangaFushiPage(
          item: null,
          bookKey: 'aidoku-${sha256.convert(utf8.encode(identity))}',
          onlineChapter: resolved,
        ),
      );
    }
    return FushiPageScaffold(
      title: chapterTitle,
      subtitle: widget.manga['title']?.toString(),
      body: _error != null
          ? Center(child: Text('$_error'))
          : Center(child: adaptiveIndicator(context: context)),
    );
  }
}

/// User-facing text for an Aidoku failure.
///
/// Cloudflare-protected sources (MangaFire, Comix, …) can't be reached by the
/// headless WebAssembly runtime — it has no browser to solve the JavaScript
/// challenge — so the runtime surfaces a dedicated `CLOUDFLARE_CHALLENGE` code
/// instead of an opaque `JsonParseError`. Turn that into an actionable line
/// rather than dumping the exception's `toString()`.
String aidokuErrorMessage(Object? error) {
  if (error is AidokuRuntimeException &&
      error.code == kAidokuCloudflareChallengeCode) {
    return t.manga_source_cloudflare_blocked;
  }
  return '$error';
}

/// Aidoku 章节的展示标题：标题为空时回退到卷/话号。
///
/// 公开是因为 `AidokuLibraryAdapter.chaptersOf` 归一化章节时要用同一份
/// 回退逻辑——复制一份必然和这里漂移。
String aidokuChapterDisplayTitle(Map<String, Object?> chapter) {
  final String title = chapter['title']?.toString().trim() ?? '';
  if (title.isNotEmpty) return title;
  final String volume = _aidokuNumber(chapter['volume_number']);
  final String number = _aidokuNumber(chapter['chapter_number']);
  if (volume.isNotEmpty && number.isNotEmpty) {
    return 'Vol. $volume · Ch. $number';
  }
  if (number.isNotEmpty) return 'Ch. $number';
  if (volume.isNotEmpty) return 'Vol. $volume';
  return chapter['key']?.toString() ?? '';
}


String _aidokuNumber(Object? value) {
  if (value is! num) return '';
  final double number = value.toDouble();
  if (number == number.truncateToDouble()) return number.toInt().toString();
  return number.toString().replaceFirst(RegExp(r'0+$'), '');
}

class _AidokuCover extends StatelessWidget {
  const _AidokuCover({required this.url, this.referer});

  final String? url;
  final String? referer;

  @override
  Widget build(BuildContext context) {
    final String value = url?.trim() ?? '';
    if (value.isEmpty) {
      return const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }
    return Image.network(
      value,
      fit: BoxFit.cover,
      headers: <String, String>{
        'User-Agent': kAidokuUserAgent,
        if (referer != null) 'Referer': referer!,
      },
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}

String? _aidokuHttpsUrl(Object? value) {
  final String candidate = value?.toString().trim() ?? '';
  return Uri.tryParse(candidate)?.isScheme('https') == true ? candidate : null;
}
