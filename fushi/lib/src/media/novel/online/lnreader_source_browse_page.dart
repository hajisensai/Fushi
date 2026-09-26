import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare_action.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_novel_detail_page.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

enum _BrowseMode { popular, latest, search }

/// 一个小说源（LNReader 插件）的浏览页：热门 / 最新 / 搜索 + 筛选 + 封面网格。
///
/// 版式与漫画 / 视频的 `MihonSourceBrowsePage` 一致（页头搜索框 + 筛选按钮、
/// 热门 / 最新分段、2~8 列封面网格、末尾「加载更多」格）。差别只在筛选语义：
/// LNReader 的筛选作用在 `popularNovels` 上（搜索只收关键词），所以应用筛选会
/// 回到「热门」并带上筛选值，而不是像 Mihon 那样切到搜索。
class LnReaderSourceBrowsePage extends StatefulWidget {
  const LnReaderSourceBrowsePage({
    required this.manager,
    required this.plugin,
    super.key,
  });

  final LnReaderManager manager;
  final LnReaderInstalledPlugin plugin;

  @override
  State<LnReaderSourceBrowsePage> createState() =>
      _LnReaderSourceBrowsePageState();
}

class _LnReaderSourceBrowsePageState extends State<LnReaderSourceBrowsePage> {
  final TextEditingController _searchController = TextEditingController();
  LnReaderPluginInfo? _info;
  List<LnReaderFilter> _filters = const <LnReaderFilter>[];
  bool _filtersTouched = false;
  List<LnReaderNovelItem> _items = const <LnReaderNovelItem>[];
  _BrowseMode _mode = _BrowseMode.popular;
  bool _loading = true;
  bool _hasNextPage = false;
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final LnReaderPluginInfo info = await widget.manager.load(widget.plugin);
      if (!mounted) return;
      _info = info;
      _filters = info.filters;
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
    if (_info == null) return;
    if (!reset && (_loading || !_hasNextPage)) return;
    final int generation = reset ? ++_generation : _generation;
    final int page = reset ? 1 : _page + 1;
    final _BrowseMode mode = _mode;
    final String query = _searchController.text.trim();
    final Map<String, Object?>? filterValues = _filtersTouched
        ? lnReaderFilterValues(_filters)
        : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<LnReaderNovelItem> response = switch (mode) {
        _BrowseMode.search => await widget.manager.runtime.search(
          widget.plugin.id,
          query: query,
          page: page,
        ),
        _BrowseMode.popular ||
        _BrowseMode.latest => await widget.manager.runtime.popular(
          widget.plugin.id,
          page: page,
          latest: mode == _BrowseMode.latest,
          filters: filterValues,
        ),
      };
      if (!mounted || generation != _generation) return;
      setState(() {
        final List<LnReaderNovelItem> previous = reset
            ? const <LnReaderNovelItem>[]
            : _items;
        final Set<String> seen = previous
            .map((LnReaderNovelItem item) => item.path)
            .toSet();
        final List<LnReaderNovelItem> additions = response
            .where((LnReaderNovelItem item) => seen.add(item.path))
            .toList(growable: false);
        _items = <LnReaderNovelItem>[...previous, ...additions];
        _page = page;
        // LNReader 插件不报「还有下一页」：一页有新条目就认为可能还有。
        _hasNextPage = additions.isNotEmpty;
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

  Future<void> _showFilters() async {
    if (_filters.isEmpty) return;
    final List<LnReaderFilter>? updated =
        await showAppDialog<List<LnReaderFilter>>(
          context: context,
          builder: (BuildContext dialogContext) => LnReaderFilterDialog(
            initial: _filters,
            defaults: _info?.filters ?? const <LnReaderFilter>[],
          ),
        );
    if (updated == null || !mounted) return;
    _filters = updated;
    _filtersTouched = true;
    _searchController.clear();
    _mode = _BrowseMode.popular;
    await _load(reset: true);
  }

  void _openDetails(LnReaderNovelItem item) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => LnReaderNovelDetailPage(
          manager: widget.manager,
          plugin: widget.plugin,
          item: item,
          imageHeaders: _info?.imageHeaders ?? const <String, String>{},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: widget.plugin.name,
      headerBottom: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('novel_browse_search_field'),
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t.novel_source_search_hint,
                  prefixIcon: const Icon(Icons.search),
                ),
                onSubmitted: (String value) {
                  if (value.trim().isEmpty) return;
                  _mode = _BrowseMode.search;
                  unawaited(_load(reset: true));
                },
              ),
            ),
            if (_filters.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              IconButton(
                key: const ValueKey<String>('novel_browse_filters'),
                tooltip: t.novel_source_filters_title,
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
            child: SegmentedButton<_BrowseMode>(
              segments: <ButtonSegment<_BrowseMode>>[
                ButtonSegment<_BrowseMode>(
                  value: _BrowseMode.popular,
                  label: Text(t.mihon_source_popular),
                ),
                ButtonSegment<_BrowseMode>(
                  value: _BrowseMode.latest,
                  label: Text(t.mihon_source_latest),
                ),
              ],
              selected: <_BrowseMode>{
                _mode == _BrowseMode.latest
                    ? _BrowseMode.latest
                    : _BrowseMode.popular,
              },
              onSelectionChanged: (Set<_BrowseMode> value) {
                _mode = value.first;
                _searchController.clear();
                unawaited(_load(reset: true));
              },
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _cloudflareAction() => LnReaderCloudflareAction(
    cloudflare: widget.manager.cloudflare,
    pluginId: widget.plugin.id,
    onVerified: () =>
        unawaited(_info == null ? _initialise() : _load(reset: true)),
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
              OutlinedButton.icon(
                onPressed: () => unawaited(
                  _info == null ? _initialise() : _load(reset: true),
                ),
                icon: const Icon(Icons.refresh),
                label: Text(t.refresh),
              ),
              const SizedBox(height: 8),
              _cloudflareAction(),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      // 被 Cloudflare 拦下的插件多半不抛错、只回空列表（fetchText 吞掉 403）。
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.novel_source_no_results),
            const SizedBox(height: 12),
            _cloudflareAction(),
          ],
        ),
      );
    }
    final Map<String, String> pluginHeaders =
        _info?.imageHeaders ?? const <String, String>{};
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return GridView.builder(
          padding: withBottomSafeInset(context, const EdgeInsets.all(16)),
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
                        key: const ValueKey<String>('novel_browse_more'),
                        onPressed: () => unawaited(_load(reset: false)),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
              );
            }
            final LnReaderNovelItem item = _items[index];
            return FushiCard(
              key: ValueKey<String>('novel_browse_item_${item.path}'),
              padding: EdgeInsets.zero,
              onTap: () => _openDetails(item),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: LnReaderCover(
                      url: item.cover,
                      site: widget.plugin.site,
                      pluginHeaders: pluginHeaders,
                      cloudflare: widget.manager.cloudflare,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      item.name,
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

/// 小说封面：插件给的封面地址，请求头按 [lnReaderImageHeaders] 装配（浏览器 UA +
/// Referer=站点 打底、插件 `imageRequestInit` 覆盖、Cloudflare 放行 cookie），走
/// app 代理出口的磁盘缓存 [AppCachedHttpImage]（超时 / 5xx 自动退避重试，滚动
/// 往返与重进页面不重复下载）。缺图 / 插件占位图 / 失败统一画书本图标。
class LnReaderCover extends StatelessWidget {
  const LnReaderCover({
    required this.url,
    required this.site,
    this.pluginHeaders = const <String, String>{},
    this.cloudflare,
    super.key,
  });

  final String? url;

  /// 插件站点：相对地址的兜底基址，也是默认 Referer。
  final String site;

  /// 插件 `imageRequestInit.headers`。
  final Map<String, String> pluginHeaders;
  final LnReaderCloudflare? cloudflare;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = ColoredBox(
      // 与扩展行图标占位同一个设计 token（不在页面里另挑 colorScheme 色）。
      color: FushiDesignTokens.of(context).surfaces.group,
      child: const Center(child: Icon(Icons.menu_book_outlined, size: 36)),
    );
    final ImageProvider<Object>? image = lnReaderCoverImage(
      url,
      site: site,
      pluginHeaders: pluginHeaders,
      cloudflare: cloudflare,
    );
    if (image == null) return fallback;
    return Image(
      image: image,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback,
      loadingBuilder: (_, Widget child, ImageChunkEvent? progress) =>
          progress == null ? child : fallback,
    );
  }
}

/// 封面地址 → 图片来源；不可用（空 / 插件「无封面」占位 / 本机地址 / 认不出的
/// scheme）返回 null。
///
/// 宿主脚本已按站点补全相对地址，这里再兜一次底（旧缓存结果、插件 `parseNovel`
/// 之外的来源）。`data:` 内联图直接解码，不发请求。
ImageProvider<Object>? lnReaderCoverImage(
  String? url, {
  required String site,
  Map<String, String> pluginHeaders = const <String, String>{},
  LnReaderCloudflare? cloudflare,
}) {
  final String value = url?.trim() ?? '';
  if (value.isEmpty || isLnReaderPlaceholderCover(value)) return null;
  if (value.startsWith('data:')) {
    final UriData? data = Uri.tryParse(value)?.data;
    if (data == null || !data.mimeType.startsWith('image/')) return null;
    try {
      return MemoryImage(data.contentAsBytes());
    } on FormatException {
      return null;
    }
  }
  final Uri? base = Uri.tryParse(site);
  final Uri? parsed = Uri.tryParse(value);
  final Uri? uri = parsed == null
      ? null
      : parsed.hasScheme || base == null
      ? parsed
      : base.resolveUri(parsed);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      isLnReaderBlockedHost(uri.host)) {
    return null;
  }
  return AppCachedHttpImage(
    uri.toString(),
    headers: lnReaderImageHeaders(
      uri: uri,
      referer: site,
      pluginHeaders: pluginHeaders,
      cloudflare: cloudflare,
    ),
  );
}

/// 插件筛选对话框：按种类出控件（下拉 / 文本 / 开关 / 多选 / 三态多选）。
class LnReaderFilterDialog extends StatefulWidget {
  const LnReaderFilterDialog({
    required this.initial,
    required this.defaults,
    super.key,
  });

  final List<LnReaderFilter> initial;

  /// 插件自带的默认值，「重置」回到它。
  final List<LnReaderFilter> defaults;

  @override
  State<LnReaderFilterDialog> createState() => _LnReaderFilterDialogState();
}

class _LnReaderFilterDialogState extends State<LnReaderFilterDialog> {
  late List<LnReaderFilter> _filters = List<LnReaderFilter>.of(widget.initial);

  void _set(int index, Object value) =>
      setState(() => _filters[index] = _filters[index].withValue(value));

  @override
  Widget build(BuildContext context) {
    // 普通 AlertDialog：内含 Dropdown / FilterChip，`.adaptive` 在 iOS / macOS 主题
    // 下没有 Material 祖先。
    return AlertDialog(
      title: Text(t.novel_source_filters_title),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (int i = 0; i < _filters.length; i++) _buildFilter(i),
          ],
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => setState(
            () => _filters = List<LnReaderFilter>.of(widget.defaults),
          ),
          child: Text(t.novel_source_filters_reset),
        ),
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context, _filters),
          child: Text(t.novel_source_filters_apply),
        ),
      ],
    );
  }

  Widget _buildFilter(int index) {
    final LnReaderFilter filter = _filters[index];
    final Widget control = switch (filter.type) {
      LnReaderFilterType.picker => DropdownButtonFormField<String>(
        key: ValueKey<String>('novel_filter_${filter.key}'),
        value:
            filter.options.any(
              (LnReaderFilterOption o) => o.value == filter.value,
            )
            ? filter.value as String
            : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: filter.label),
        items: <DropdownMenuItem<String>>[
          for (final LnReaderFilterOption option in filter.options)
            DropdownMenuItem<String>(
              value: option.value,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (String? value) => _set(index, value ?? ''),
      ),
      LnReaderFilterType.text => TextFormField(
        key: ValueKey<String>('novel_filter_${filter.key}'),
        initialValue: filter.value as String,
        decoration: InputDecoration(labelText: filter.label),
        onChanged: (String value) => _set(index, value),
      ),
      LnReaderFilterType.toggle => SwitchListTile.adaptive(
        key: ValueKey<String>('novel_filter_${filter.key}'),
        contentPadding: EdgeInsets.zero,
        title: Text(filter.label),
        value: filter.value as bool,
        onChanged: (bool value) => _set(index, value),
      ),
      LnReaderFilterType.checkbox => _chipGroup(
        filter,
        selected: (String value) =>
            (filter.value as List<String>).contains(value),
        onTap: (String value) {
          final List<String> current = List<String>.of(
            filter.value as List<String>,
          );
          current.contains(value) ? current.remove(value) : current.add(value);
          _set(index, current);
        },
      ),
      LnReaderFilterType.excludableCheckbox => _excludableGroup(index, filter),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: control,
    );
  }

  Widget _chipGroup(
    LnReaderFilter filter, {
    required bool Function(String value) selected,
    required void Function(String value) onTap,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(filter.label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final LnReaderFilterOption option in filter.options)
            FilterChip(
              label: Text(option.label),
              selected: selected(option.value),
              onSelected: (_) => onTap(option.value),
            ),
        ],
      ),
    ],
  );

  /// 三态：未选 → 包含 → 排除 → 未选。
  Widget _excludableGroup(int index, LnReaderFilter filter) {
    final Map<String, List<String>> value =
        filter.value as Map<String, List<String>>;
    final List<String> include = value['include'] ?? const <String>[];
    final List<String> exclude = value['exclude'] ?? const <String>[];
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(filter.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final LnReaderFilterOption option in filter.options)
              FilterChip(
                label: Text(option.label),
                selected:
                    include.contains(option.value) ||
                    exclude.contains(option.value),
                selectedColor: exclude.contains(option.value)
                    ? scheme.errorContainer
                    : null,
                avatar: exclude.contains(option.value)
                    ? const Icon(Icons.remove, size: 16)
                    : null,
                onSelected: (_) {
                  final List<String> nextInclude = List<String>.of(include);
                  final List<String> nextExclude = List<String>.of(exclude);
                  if (nextInclude.remove(option.value)) {
                    nextExclude.add(option.value);
                  } else if (!nextExclude.remove(option.value)) {
                    nextInclude.add(option.value);
                  }
                  _set(index, <String, List<String>>{
                    'include': nextInclude,
                    'exclude': nextExclude,
                  });
                },
              ),
          ],
        ),
      ],
    );
  }
}
