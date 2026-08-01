import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_library.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_online_reader_page.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki/utils.dart';

enum _MihonBrowseMode { popular, latest, search }

class MihonSourceBrowsePage extends StatefulWidget {
  const MihonSourceBrowsePage({
    required this.manager,
    required this.source,
    super.key,
  });

  final MihonManager manager;
  final MangaOnlineSourceRow source;

  @override
  State<MihonSourceBrowsePage> createState() => _MihonSourceBrowsePageState();
}

class _MihonSourceBrowsePageState extends State<MihonSourceBrowsePage> {
  final TextEditingController _searchController = TextEditingController();
  MihonSourceContext? _sourceContext;
  List<MihonManga> _items = const <MihonManga>[];
  List<MihonFilter> _filters = const <MihonFilter>[];
  _MihonBrowseMode _mode = _MihonBrowseMode.popular;
  bool _loading = true;
  bool _hasNextPage = false;
  int _page = 1;
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
      final MihonSourceContext context =
          await widget.manager.contextForSource(widget.source);
      final List<MihonFilter> filters = await widget.manager.runtime.getFilters(
        context.extension,
        context.source,
        preferences: context.preferences,
      );
      if (!mounted) return;
      _sourceContext = context;
      _filters = filters;
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
    final MihonSourceContext? context = _sourceContext;
    if (context == null) return;
    if (reset) {
      _page = 1;
    } else {
      _page++;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MihonMangaPage response = switch (_mode) {
        _MihonBrowseMode.popular => await widget.manager.runtime.getPopular(
            context.extension,
            context.source,
            page: _page,
            preferences: context.preferences,
          ),
        _MihonBrowseMode.latest => await widget.manager.runtime.getLatest(
            context.extension,
            context.source,
            page: _page,
            preferences: context.preferences,
          ),
        _MihonBrowseMode.search => await widget.manager.runtime.search(
            context.extension,
            context.source,
            page: _page,
            query: _searchController.text.trim(),
            filters: _filters,
            preferences: context.preferences,
          ),
      };
      if (!mounted) return;
      setState(() {
        _items =
            reset ? response.items : <MihonManga>[..._items, ...response.items];
        _hasNextPage = response.hasNextPage;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      if (!reset) _page--;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _showFilters() async {
    if (_filters.isEmpty) return;
    final List<MihonFilter>? updated = await showAppDialog<List<MihonFilter>>(
      context: context,
      builder: (BuildContext dialogContext) => _MihonFilterDialog(
        initial: _filters,
      ),
    );
    if (updated == null || !mounted) return;
    _filters = updated;
    _mode = _MihonBrowseMode.search;
    await _load(reset: true);
  }

  void _openDetails(MihonManga manga) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonMangaDetailPage(
          manager: widget.manager,
          sourceContext: _sourceContext!,
          manga: manga,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return HibikiPageScaffold(
      title: widget.source.name,
      headerBottom: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t.mihon_source_search,
                  prefixIcon: const Icon(Icons.search),
                ),
                onSubmitted: (String _) {
                  _mode = _MihonBrowseMode.search;
                  unawaited(_load(reset: true));
                },
              ),
            ),
            if (_filters.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              IconButton(
                tooltip: t.mihon_source_preferences,
                onPressed: _showFilters,
                icon: const Icon(Icons.tune),
              ),
            ],
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<_MihonBrowseMode>(
              segments: <ButtonSegment<_MihonBrowseMode>>[
                ButtonSegment<_MihonBrowseMode>(
                  value: _MihonBrowseMode.popular,
                  label: Text(t.mihon_source_popular),
                ),
                ButtonSegment<_MihonBrowseMode>(
                  value: _MihonBrowseMode.latest,
                  label: Text(t.mihon_source_latest),
                ),
              ],
              selected: <_MihonBrowseMode>{
                _mode == _MihonBrowseMode.latest
                    ? _MihonBrowseMode.latest
                    : _MihonBrowseMode.popular,
              },
              onSelectionChanged: (Set<_MihonBrowseMode> value) {
                _mode = value.first;
                unawaited(_load(reset: true));
              },
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

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
    if (_items.isEmpty) {
      return Center(child: Text(t.mihon_source_no_results));
    }
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
            final MihonManga manga = _items[index];
            return HibikiCard(
              padding: EdgeInsets.zero,
              onTap: () => _openDetails(manga),
              // HibikiCard 内部已用 Material(clipBehavior: antiAlias) 按同一
              // 圆角 token 裁剪，这里不再多包一层 ClipRRect。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: MihonSourceImage(
                      runtime: widget.manager.runtime,
                      context: _sourceContext!,
                      url: manga.coverUrl,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      manga.title,
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

class MihonMangaDetailPage extends StatefulWidget {
  const MihonMangaDetailPage({
    required this.manager,
    required this.sourceContext,
    required this.manga,
    super.key,
  });

  final MihonManager manager;
  final MihonSourceContext sourceContext;
  final MihonManga manga;

  @override
  State<MihonMangaDetailPage> createState() => _MihonMangaDetailPageState();
}

class _MihonMangaDetailPageState extends State<MihonMangaDetailPage> {
  MihonManga? _details;
  List<MihonChapter> _chapters = const <MihonChapter>[];
  String? _libraryBookKey;
  MihonLibraryEntry? _libraryEntry;
  bool _libraryBusy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final MihonManga details = await widget.manager.runtime.getDetails(
        widget.sourceContext.extension,
        widget.sourceContext.source,
        widget.manga,
        preferences: widget.sourceContext.preferences,
      );
      final List<MihonChapter> chapters =
          await widget.manager.runtime.getChapters(
        widget.sourceContext.extension,
        widget.sourceContext.source,
        details,
        preferences: widget.sourceContext.preferences,
      );
      final MihonLibraryService library = MihonLibraryService(widget.manager);
      EpubBookRow? shelfBook =
          await library.find(widget.sourceContext, details);
      if (shelfBook != null) {
        await library.refresh(
          bookKey: shelfBook.bookKey,
          existing: MihonLibraryEntry.tryParse(shelfBook.sourceMetadata),
          manga: details,
          chapters: chapters,
        );
        shelfBook =
            await widget.manager.database.getEpubBook(shelfBook.bookKey);
      }
      if (mounted) {
        setState(() {
          _details = details;
          _chapters = chapters;
          _libraryBookKey = shelfBook?.bookKey;
          _libraryEntry = MihonLibraryEntry.tryParse(shelfBook?.sourceMetadata);
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _addToBookshelf() async {
    final MihonManga? details = _details;
    if (details == null || _libraryBusy) return;
    setState(() => _libraryBusy = true);
    try {
      final EpubBookRow row = await MihonLibraryService(widget.manager).add(
        context: widget.sourceContext,
        manga: details,
        chapters: _chapters,
      );
      if (!mounted) return;
      setState(() {
        _libraryBookKey = row.bookKey;
        _libraryEntry = MihonLibraryEntry.tryParse(row.sourceMetadata);
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance
          .log('MihonMangaDetailPage.addToBookshelf', error, stack);
      debugPrint('[Mihon] add to bookshelf failed: $error');
      if (mounted) HibikiToast.show(msg: '$error');
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
  }

  Future<void> _continueReading() async {
    final MihonLibraryEntry? entry = _libraryEntry;
    if (entry == null || entry.chapters.isEmpty) return;
    final int chapterIndex = MihonLibraryService.initialChapterIndex(entry);
    await _openChapter(entry.chapters[chapterIndex]);
  }

  Future<void> _openChapter(MihonChapter chapter) async {
    final String? libraryBookKey = _libraryBookKey;
    if (libraryBookKey != null) {
      final MihonLibraryEntry? entry = _libraryEntry;
      if (entry != null) {
        final int chapterIndex = entry.chapters.indexWhere(
          (MihonChapter value) => value.url == chapter.url,
        );
        if (chapterIndex >= 0 && chapterIndex != entry.currentChapterIndex) {
          _libraryEntry =
              await MihonLibraryService(widget.manager).selectChapter(
            bookKey: libraryBookKey,
            entry: entry,
            chapterIndex: chapterIndex,
          );
          if (mounted) setState(() {});
        }
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonChapterReaderPage(
          manager: widget.manager,
          context: widget.sourceContext,
          manga: _details ?? widget.manga,
          chapter: chapter,
          libraryBookKey: libraryBookKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MihonManga details = _details ?? widget.manga;
    return HibikiPageScaffold(
      title: details.title,
      subtitle: widget.sourceContext.source.name,
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
                            borderRadius: HibikiBorderRadius.poster,
                            child: MihonSourceImage(
                              runtime: widget.manager.runtime,
                              context: widget.sourceContext,
                              url: details.coverUrl,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (details.author?.isNotEmpty == true)
                                Text(details.author!),
                              if (details.artist?.isNotEmpty == true)
                                Text(details.artist!),
                              if (details.genre?.isNotEmpty ==
                                  true) ...<Widget>[
                                const SizedBox(height: 8),
                                Text(details.genre!),
                              ],
                              if (details.description?.isNotEmpty ==
                                  true) ...<Widget>[
                                const SizedBox(height: 12),
                                Text(details.description!),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          key: const ValueKey<String>(
                            'mihon_add_to_bookshelf',
                          ),
                          onPressed: _libraryBookKey == null && !_libraryBusy
                              ? _addToBookshelf
                              : null,
                          icon: Icon(
                            _libraryBookKey == null
                                ? Icons.library_add_outlined
                                : Icons.check,
                          ),
                          label: Text(
                            _libraryBookKey == null
                                ? t.mihon_add_to_bookshelf
                                : t.mihon_in_bookshelf,
                          ),
                        ),
                        if (_libraryBookKey != null)
                          OutlinedButton.icon(
                            onPressed:
                                _chapters.isEmpty ? null : _continueReading,
                            icon: const Icon(Icons.play_arrow),
                            label: Text(t.book_continue_reading),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      t.mihon_chapters_title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    for (final MihonChapter chapter in _chapters)
                      HibikiCard(
                        padding: EdgeInsets.zero,
                        child: HibikiListItem(
                          title: Text(chapter.name),
                          subtitle: chapter.scanlator?.isNotEmpty == true
                              ? Text(chapter.scanlator!)
                              : null,
                          trailing: Icon(
                            _libraryEntry?.currentChapter?.url == chapter.url
                                ? Icons.play_circle_outline
                                : Icons.chevron_right,
                          ),
                          onTap: () => unawaited(_openChapter(chapter)),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class MihonSourceImage extends StatefulWidget {
  const MihonSourceImage({
    required this.runtime,
    required this.context,
    required this.url,
    super.key,
  });

  final MihonRuntime runtime;
  final MihonSourceContext context;
  final String? url;

  @override
  State<MihonSourceImage> createState() => _MihonSourceImageState();
}

class _MihonSourceImageState extends State<MihonSourceImage> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(MihonSourceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.context.source.id != widget.context.source.id) {
      _reload();
    }
  }

  void _reload() {
    final String? url = widget.url;
    _future = url == null || url.isEmpty
        ? null
        : widget.runtime.fetchSourceImage(
            widget.context.extension,
            widget.context.source,
            url,
            preferences: widget.context.preferences,
          );
  }

  @override
  Widget build(BuildContext context) {
    final Future<Uint8List>? future = _future;
    if (future == null) return const ColoredBox(color: Color(0xff303030));
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        if (snapshot.hasData) {
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        }
        if (snapshot.hasError) {
          return const ColoredBox(
            color: Color(0xff303030),
            child: Icon(Icons.broken_image_outlined),
          );
        }
        return const ColoredBox(
          color: Color(0xff303030),
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}

class _MihonFilterDialog extends StatefulWidget {
  const _MihonFilterDialog({required this.initial});

  final List<MihonFilter> initial;

  @override
  State<_MihonFilterDialog> createState() => _MihonFilterDialogState();
}

class _MihonFilterDialogState extends State<_MihonFilterDialog> {
  late final List<MihonFilter> _filters = List<MihonFilter>.of(widget.initial);

  MihonFilter _withState(MihonFilter filter, Object? state) => MihonFilter(
        name: filter.name,
        kind: filter.kind,
        state: state,
        values: filter.values,
        children: filter.children,
      );

  MihonFilter _withChildren(
    MihonFilter filter,
    List<MihonFilter> children,
  ) =>
      MihonFilter(
        name: filter.name,
        kind: filter.kind,
        state: filter.state,
        values: filter.values,
        children: children,
      );

  void _replace(int index, MihonFilter filter) {
    setState(() {
      _filters[index] = filter;
    });
  }

  Widget _buildFilter(
    MihonFilter filter,
    ValueChanged<MihonFilter> onChanged,
  ) {
    return switch (filter.kind) {
      MihonFilterKind.header => HibikiListItem(
          title: Text(
            filter.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      MihonFilterKind.separator => const Divider(),
      MihonFilterKind.checkBox => _MihonCheckRow(
          label: filter.name,
          selected: filter.state == true,
          onChanged: (bool value) => onChanged(_withState(filter, value)),
        ),
      MihonFilterKind.text => TextFormField(
          initialValue: filter.state?.toString() ?? '',
          decoration: InputDecoration(labelText: filter.name),
          onChanged: (String value) => onChanged(_withState(filter, value)),
        ),
      MihonFilterKind.select when filter.values.isNotEmpty =>
        DropdownButtonFormField<int>(
          value: (filter.state as int? ?? 0).clamp(0, filter.values.length - 1),
          decoration: InputDecoration(labelText: filter.name),
          items: <DropdownMenuItem<int>>[
            for (int value = 0; value < filter.values.length; value++)
              DropdownMenuItem<int>(
                value: value,
                child: Text(filter.values[value]),
              ),
          ],
          onChanged: (int? value) => onChanged(_withState(filter, value ?? 0)),
        ),
      MihonFilterKind.triState => DropdownButtonFormField<int>(
          value: (filter.state as int? ?? 0).clamp(0, 2),
          decoration: InputDecoration(labelText: filter.name),
          items: <DropdownMenuItem<int>>[
            DropdownMenuItem<int>(
              value: 0,
              child: Text(t.mihon_filter_ignore),
            ),
            DropdownMenuItem<int>(
              value: 1,
              child: Text(t.mihon_filter_include),
            ),
            DropdownMenuItem<int>(
              value: 2,
              child: Text(t.mihon_filter_exclude),
            ),
          ],
          onChanged: (int? value) => onChanged(_withState(filter, value ?? 0)),
        ),
      MihonFilterKind.group => ExpansionTile(
          title: Text(filter.name),
          children: <Widget>[
            for (int index = 0; index < filter.children.length; index++)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16),
                child: _buildFilter(
                  filter.children[index],
                  (MihonFilter child) {
                    final List<MihonFilter> children =
                        List<MihonFilter>.of(filter.children);
                    children[index] = child;
                    onChanged(_withChildren(filter, children));
                  },
                ),
              ),
          ],
        ),
      MihonFilterKind.sort when filter.values.isNotEmpty =>
        _MihonSortFilterField(
          filter: filter,
          onChanged: (Object? state) => onChanged(_withState(filter, state)),
        ),
      _ => HibikiListItem(
          title: Text(filter.name),
          subtitle: Text(t.mihon_extension_incompatible),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.mihon_source_preferences),
      content: SizedBox(
        width: 420,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _filters.length,
          itemBuilder: (BuildContext context, int index) {
            final MihonFilter filter = _filters[index];
            return _buildFilter(
              filter,
              (MihonFilter value) => _replace(index, value),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _filters),
          child: Text(t.dialog_ok),
        ),
      ],
    );
  }
}

class _MihonSortFilterField extends StatelessWidget {
  const _MihonSortFilterField({
    required this.filter,
    required this.onChanged,
  });

  final MihonFilter filter;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final Map<Object?, Object?> state = filter.state is Map<Object?, Object?>
        ? filter.state! as Map<Object?, Object?>
        : const <Object?, Object?>{};
    final int index = ((state['index'] as num?)?.toInt() ?? 0)
        .clamp(0, filter.values.length - 1);
    final bool ascending = state['ascending'] != false;
    void update({int? nextIndex, bool? nextAscending}) {
      onChanged(<String, Object?>{
        'index': nextIndex ?? index,
        'ascending': nextAscending ?? ascending,
      });
    }

    return Column(
      children: <Widget>[
        DropdownButtonFormField<int>(
          value: index,
          decoration: InputDecoration(labelText: filter.name),
          items: <DropdownMenuItem<int>>[
            for (int value = 0; value < filter.values.length; value++)
              DropdownMenuItem<int>(
                value: value,
                child: Text(filter.values[value]),
              ),
          ],
          onChanged: (int? value) => update(nextIndex: value ?? 0),
        ),
        HibikiListItem(
          title: Text(
            ascending ? t.mihon_filter_ascending : t.mihon_filter_descending,
          ),
          trailing: Switch.adaptive(
            value: ascending,
            onChanged: (bool value) => update(nextAscending: value),
          ),
          onTap: () => update(nextAscending: !ascending),
        ),
      ],
    );
  }
}

/// 扩展筛选器里的复选行。
///
/// 框架的 `CheckboxListTile` 是被 MD3 守卫禁用的本地 chrome；共享的
/// [HibikiListItem] 没有内建复选语义，所以这里把「点整行 = 切换」显式接上，
/// 与 `CheckboxListTile` 的交互等价。
class _MihonCheckRow extends StatelessWidget {
  const _MihonCheckRow({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => HibikiListItem(
        title: Text(label),
        leading: Checkbox(
          value: selected,
          onChanged: (bool? value) => onChanged(value == true),
        ),
        onTap: () => onChanged(!selected),
      );
}
