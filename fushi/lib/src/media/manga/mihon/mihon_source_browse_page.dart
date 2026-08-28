import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cover_cache.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/utils.dart';

enum _MihonBrowseMode { popular, latest, search }

/// 浏览页要浏览的那「一个源」从哪来。
///
/// 两个变体的差别只在**上下文怎么拿到**和**能不能落库**，网格、搜索、分页、
/// 封面代理全部同一套代码——所以这里用 sealed 穷尽，而不是给页面塞一堆可空参数
/// 再靠「恰有一个非空」的隐式约定分流。
sealed class MihonBrowseTarget {
  const MihonBrowseTarget();
}

/// 已安装并登记入库的源：上下文和用户偏好都从库里读，可以进详情、可以入库。
class MihonInstalledTarget extends MihonBrowseTarget {
  const MihonInstalledTarget(this.row);

  final MangaOnlineSourceRow row;
}

/// 试用预览里的源：上下文来自 staged 会话，库里根本没有这个扩展。
///
/// 因此**只读**——不能进详情页。详情页会走 `MihonLibraryService.add()` 把书写进
/// 书架，而那要求扩展和源都已在库里登记；对一个随时可能被放弃的预览来说，那会
/// 留下指向不存在扩展的孤儿行。预览的目的是「看看这个源有没有我要的漫画」，
/// 网格 + 搜索 + 封面已经够判断，真要读就先装。
class MihonPreviewTarget extends MihonBrowseTarget {
  const MihonPreviewTarget({
    required this.session,
    required this.source,
  });

  final MihonPreviewSession session;
  final MihonSource source;
}

class MihonSourceBrowsePage extends StatefulWidget {
  const MihonSourceBrowsePage({
    required this.manager,
    required this.target,
    super.key,
    this.footer,
  });

  final MihonManager manager;
  final MihonBrowseTarget target;

  /// 钉在正文底部的操作条。预览用它放「放弃 / 信任并安装」。
  final Widget? footer;

  @override
  State<MihonSourceBrowsePage> createState() => _MihonSourceBrowsePageState();
}

class _MihonSourceBrowsePageState extends State<MihonSourceBrowsePage> {
  final TextEditingController _searchController = TextEditingController();
  final MihonSourceImageLoadQueue _imageLoadQueue =
      MihonSourceImageLoadQueue(maxConcurrent: 4);
  MihonSourceContext? _sourceContext;
  List<MihonManga> _items = const <MihonManga>[];
  List<MihonFilter> _filters = const <MihonFilter>[];
  _MihonBrowseMode _mode = _MihonBrowseMode.popular;
  bool _loading = true;
  bool _hasNextPage = false;
  int _page = 1;
  int _loadGeneration = 0;
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

  /// 预览态只读：封面不可点，也没有详情页可去。
  bool get _readOnly => widget.target is MihonPreviewTarget;

  Future<void> _initialise() async {
    try {
      final MihonSourceContext context = switch (widget.target) {
        MihonInstalledTarget(:final MangaOnlineSourceRow row) =>
          await widget.manager.contextForSource(row),
        MihonPreviewTarget(
          :final MihonPreviewSession session,
          :final MihonSource source,
        ) =>
          session.contextFor(source),
      };
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
    if (!reset && (_loading || !_hasNextPage)) return;
    final int generation = reset ? ++_loadGeneration : _loadGeneration;
    final int requestedPage = reset ? 1 : _page + 1;
    final _MihonBrowseMode requestedMode = _mode;
    final String requestedQuery = _searchController.text.trim();
    final List<MihonFilter> requestedFilters = List<MihonFilter>.of(_filters);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MihonMangaPage response = switch (requestedMode) {
        _MihonBrowseMode.popular => await widget.manager.runtime.getPopular(
            context.extension,
            context.source,
            page: requestedPage,
            preferences: context.preferences,
          ),
        _MihonBrowseMode.latest => await widget.manager.runtime.getLatest(
            context.extension,
            context.source,
            page: requestedPage,
            preferences: context.preferences,
          ),
        _MihonBrowseMode.search => await widget.manager.runtime.search(
            context.extension,
            context.source,
            page: requestedPage,
            query: requestedQuery,
            filters: requestedFilters,
            preferences: context.preferences,
          ),
      };
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        final List<MihonManga> previous = reset ? const <MihonManga>[] : _items;
        final Set<String> seen =
            previous.map((MihonManga item) => item.url).toSet();
        final List<MihonManga> additions = response.items
            .where((MihonManga item) => seen.add(item.url))
            .toList(growable: false);
        _items = <MihonManga>[...previous, ...additions];
        _page = requestedPage;
        _hasNextPage = response.hasNextPage &&
            response.items.isNotEmpty &&
            (reset || additions.isNotEmpty);
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error;
      });
      if (_items.isNotEmpty) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
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
    return FushiPageScaffold(
      title: switch (widget.target) {
        MihonInstalledTarget(:final MangaOnlineSourceRow row) => row.name,
        MihonPreviewTarget(:final MihonSource source) => source.name,
      },
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
          if (widget.footer != null) widget.footer!,
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
            return FushiCard(
              padding: EdgeInsets.zero,
              onTap: _readOnly ? null : () => _openDetails(manga),
              // FushiCard 内部已用 Material(clipBehavior: antiAlias) 按同一
              // 圆角 token 裁剪，这里不再多包一层 ClipRRect。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: MihonSourceImage(
                      runtime: widget.manager.runtime,
                      cache: widget.manager.coverCache,
                      context: _sourceContext!,
                      url: manga.coverUrl,
                      loadQueue: _imageLoadQueue,
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

/// 源浏览里的作品页入口。
///
/// v88 前这里是一整个独立详情页：自己拉详情、拉章节、写书架、渲染章节列表、
/// 选章开读——和作品页逐条重复，而且**只**服务源浏览这一条路径。书架够不着它，
/// 正是「加入书架后只能看第一章」的成因之一。
///
/// 现在它只负责把 Mihon 的源上下文翻译成运行时无关的 seed，页面本体交给
/// [MangaSeriesPage]：两条入口从此共用同一套章节列表、已读标记和进度。
class MihonMangaDetailPage extends StatelessWidget {
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
  Widget build(BuildContext context) => MangaSeriesPage(
        target: SourceMangaSeriesTarget(
          service: mihonOnlineLibraryService(manager),
          seed: OnlineMangaLibraryEntry(
            runtime: OnlineMangaRuntimeKind.mihon,
            extensionPackage: sourceContext.extension.packageName,
            sourceId: sourceContext.source.id,
            series: MihonLibraryAdapter.seriesOf(manga),
            // 网格上只有标题和封面；章节由作品页进页后自己拉。
            chapters: const <OnlineMangaChapter>[],
          ),
          sourceLabel: sourceContext.source.name,
          // 未入库时封面必须经扩展的 imageProxy 取（带鉴权头），不能裸 https。
          remoteCoverBuilder: (BuildContext context) => MihonSourceImage(
            runtime: manager.runtime,
            cache: manager.coverCache,
            context: sourceContext,
            url: manga.coverUrl,
          ),
        ),
      );
}

class MihonSourceImage extends StatefulWidget {
  const MihonSourceImage({
    required this.runtime,
    required this.cache,
    required this.context,
    required this.url,
    super.key,
    this.loadQueue,
  });

  final MihonRuntime runtime;
  final MihonCoverCache cache;
  final MihonSourceContext context;
  final String? url;

  /// 浏览网格共享同一队列，避免预览一次把所有可见/预取封面同时打到漫画源。
  /// 详情页只有单张封面，可以不传。
  final MihonSourceImageLoadQueue? loadQueue;

  @override
  State<MihonSourceImage> createState() => _MihonSourceImageState();
}

class _MihonSourceImageState extends State<MihonSourceImage> {
  Future<Uint8List>? _future;
  int _generation = 0;

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
    final int generation = ++_generation;
    if (url == null || url.isEmpty) {
      _future = null;
      return;
    }
    _future = widget.cache.load(
      extensionPackage: widget.context.extension.packageName,
      sourceId: widget.context.source.id,
      url: url,
      // 只声明「本 widget 还要不要这张图」。是否真的取消由缓存层汇总所有订阅者
      // 决定：同一 key 的 in-flight 请求是共享的，不能被某一个 widget 的退场
      // 打成失败，否则同屏其它格子会一起显示破图。
      isActive: () => mounted && generation == _generation,
      fetch: (bool Function() stillWanted) {
        Future<Uint8List> fetchSource() {
          // 拿到并发名额后再复查：排队期间整批封面都滚走了就不必打漫画源。
          if (!stillWanted()) {
            return Future<Uint8List>.error(
              const MihonRuntimeException(
                'IMAGE_LOAD_CANCELLED',
                'The source image left the preview queue before it started',
              ),
            );
          }
          return widget.runtime.fetchSourceImage(
            widget.context.extension,
            widget.context.source,
            url,
            preferences: widget.context.preferences,
          );
        }

        return widget.loadQueue?.run<Uint8List>(fetchSource) ?? fetchSource();
      },
    );
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
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

/// 漫画源封面的轻量共享并发闸门。
///
/// `GridView.builder` 虽然懒建，但仍会为当前视口和 cacheExtent 同时创建多张封面；
/// 没有这个闸门时，每个 [MihonSourceImage] 都会立刻发请求。队列只限制正在执行的
/// 缓存未命中网络任务；命中磁盘的封面不占用网络并发名额，图片仍由各自 widget
/// 独立解码与渲染。
class MihonSourceImageLoadQueue {
  MihonSourceImageLoadQueue({required this.maxConcurrent})
      : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  int _active = 0;

  int get active => _active;
  int get pending => _waiters.length;

  Future<T> run<T>(Future<T> Function() operation) async {
    await _acquire();
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.addLast(waiter);
    await waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    _active--;
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
      MihonFilterKind.header => FushiListItem(
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
      _ => FushiListItem(
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
        FushiListItem(
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
/// [FushiListItem] 没有内建复选语义，所以这里把「点整行 = 切换」显式接上，
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
  Widget build(BuildContext context) => FushiListItem(
        title: Text(label),
        leading: Checkbox(
          value: selected,
          onChanged: (bool? value) => onChanged(value == true),
        ),
        onTap: () => onChanged(!selected),
      );
}
