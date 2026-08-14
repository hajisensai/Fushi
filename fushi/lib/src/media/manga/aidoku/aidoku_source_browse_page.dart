import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_reader_chapter.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
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
  late final AidokuRuntime _runtime = widget.runtime ?? DesktopAidokuRuntime();
  List<AidokuListing> _listings = const <AidokuListing>[];
  AidokuListing? _listing;
  List<Map<String, Object?>> _items = const <Map<String, Object?>>[];
  bool _loading = true;
  bool _hasNextPage = false;
  bool _searching = false;
  int _page = 1;
  int _generation = 0;
  Object? _error;

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
        builder: (BuildContext context) => _AidokuMangaDetailPage(
          package: widget.package,
          runtime: _runtime,
          manga: manga,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
        title: widget.package.name,
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
            if (_listings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DropdownButton<AidokuListing>(
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
                ),
              ),
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
          child: Text('$_error', textAlign: TextAlign.center),
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
                      child: _AidokuCover(url: manga['cover']?.toString())),
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

class _AidokuMangaDetailPage extends StatefulWidget {
  const _AidokuMangaDetailPage({
    required this.package,
    required this.runtime,
    required this.manga,
  });

  final AidokuInstalledPackage package;
  final AidokuRuntime runtime;
  final Map<String, Object?> manga;

  @override
  State<_AidokuMangaDetailPage> createState() => _AidokuMangaDetailPageState();
}

class _AidokuMangaDetailPageState extends State<_AidokuMangaDetailPage> {
  Map<String, Object?>? _details;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final Map<String, Object?> details = await widget.runtime.getDetails(
        widget.package.packagePath,
        widget.manga,
      );
      if (mounted) setState(() => _details = details);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _openChapter(Map<String, Object?> chapter) {
    final Map<String, Object?>? details = _details;
    if (details == null) return;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => _AidokuChapterReaderPage(
          package: widget.package,
          runtime: widget.runtime,
          manga: details,
          chapter: chapter,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, Object?> details = _details ?? widget.manga;
    final List<Map<String, Object?>> chapters =
        (details['chapters'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> value) => value.cast<String, Object?>())
            .toList(growable: false);
    return FushiPageScaffold(
      title: details['title']?.toString() ?? widget.package.name,
      subtitle: widget.package.name,
      body: _error != null
          ? Center(child: Text('$_error'))
          : _details == null
              ? Center(child: adaptiveIndicator(context: context))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 150,
                          height: 220,
                          child: ClipRRect(
                            borderRadius: FushiBorderRadius.poster,
                            child: _AidokuCover(
                              url: details['cover']?.toString(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(details['description']?.toString() ?? ''),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      t.mihon_chapters_title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    for (final Map<String, Object?> chapter in chapters)
                      FushiCard(
                        padding: EdgeInsets.zero,
                        child: FushiListItem(
                          title: Text(
                            _aidokuChapterTitle(chapter),
                          ),
                          subtitle: _aidokuChapterSubtitle(chapter),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openChapter(chapter),
                        ),
                      ),
                  ],
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
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String chapterTitle = _aidokuChapterTitle(widget.chapter);
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

String _aidokuChapterTitle(Map<String, Object?> chapter) {
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

Widget? _aidokuChapterSubtitle(Map<String, Object?> chapter) {
  final String scanlators =
      (chapter['scanlators'] as List<Object?>? ?? const <Object?>[]).join(', ');
  final String language = chapter['language']?.toString().trim() ?? '';
  final String value = <String>[
    if (language.isNotEmpty) language.toUpperCase(),
    if (scanlators.isNotEmpty) scanlators,
  ].join(' · ');
  return value.isEmpty ? null : Text(value);
}

String _aidokuNumber(Object? value) {
  if (value is! num) return '';
  final double number = value.toDouble();
  if (number == number.truncateToDouble()) return number.toInt().toString();
  return number.toString().replaceFirst(RegExp(r'0+$'), '');
}

class _AidokuCover extends StatelessWidget {
  const _AidokuCover({required this.url});

  final String? url;

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
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}
