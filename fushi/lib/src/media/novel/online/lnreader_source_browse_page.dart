import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare_action.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_novel_detail_page.dart';
import 'package:fushi/src/media/online/online_source_browse_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 一个小说源（LNReader 插件）的浏览页：热门 / 最新 / 搜索 + 筛选 + 封面网格。
///
/// 页面本体是三域共用的 [OnlineSourceBrowsePage]（2026-09-27「浏览」阶段 2）；
/// 这里只剩 LNReader 的差异（[_LnReaderCatalog]）：筛选作用在 `popularNovels` 上
/// （搜索只收关键词），所以应用筛选会回到「热门」并带上筛选值，而不是像 Mihon
/// 那样切到搜索；插件不报「还有下一页」，按「这一页有新条目」推断；被 Cloudflare
/// 拦下时插件多半只回空列表，所以空结果也给验证入口。
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
  late final _LnReaderCatalog _catalog = _LnReaderCatalog(
    manager: widget.manager,
    plugin: widget.plugin,
  );

  @override
  Widget build(BuildContext context) =>
      OnlineSourceBrowsePage<LnReaderNovelItem>(catalog: _catalog);
}

class _LnReaderCatalog extends OnlineSourceCatalog<LnReaderNovelItem> {
  _LnReaderCatalog({required this.manager, required this.plugin});

  static const String _popular = 'popular';
  static const String _latest = 'latest';

  final LnReaderManager manager;
  final LnReaderInstalledPlugin plugin;
  LnReaderPluginInfo? _info;
  List<LnReaderFilter> _filters = const <LnReaderFilter>[];

  @override
  String get title => plugin.name;

  @override
  String get searchHint => t.novel_source_search_hint;

  @override
  String get keyPrefix => 'novel_browse';

  @override
  String get emptyText => t.novel_source_no_results;

  /// LNReader 插件的「筛选」就是筛选（作用在热门列表上），不是源偏好。
  @override
  String get filtersTooltip => t.novel_source_filters_title;

  @override
  bool get verifyOnEmpty => true;

  @override
  bool get searchRequiresQuery => true;

  @override
  bool get clearQueryOnListingChange => true;

  @override
  Future<void> prepare() async {
    final LnReaderPluginInfo info = await manager.load(plugin);
    _info = info;
    _filters = info.filters;
  }

  @override
  List<OnlineBrowseListing> get listings => <OnlineBrowseListing>[
    OnlineBrowseListing(id: _popular, label: t.mihon_source_popular),
    OnlineBrowseListing(id: _latest, label: t.mihon_source_latest),
  ];

  @override
  bool get hasFilters => _filters.isNotEmpty;

  @override
  Future<OnlineBrowseFilterTarget?> editFilters(BuildContext context) async {
    if (_filters.isEmpty) return null;
    final List<LnReaderFilter>? updated =
        await showAppDialog<List<LnReaderFilter>>(
          context: context,
          builder: (BuildContext dialogContext) => LnReaderFilterDialog(
            initial: _filters,
            defaults: _info?.filters ?? const <LnReaderFilter>[],
          ),
        );
    if (updated == null) return null;
    _filters = updated;
    return OnlineBrowseFilterTarget.firstListing;
  }

  @override
  Future<OnlineBrowsePageResult<LnReaderNovelItem>> fetch(
    OnlineBrowseQuery query,
    int page,
  ) async {
    final List<LnReaderNovelItem> response = query.isSearch
        ? await manager.runtime.search(plugin.id, query: query.text, page: page)
        : await manager.runtime.popular(
            plugin.id,
            page: page,
            latest: query.listingId == _latest,
            // 只在用户动过筛选后才带：没动过时让插件用它自己的默认值。
            filters: query.filtered ? lnReaderFilterValues(_filters) : null,
          );
    return (items: response, hasNextPage: true);
  }

  /// LNReader 插件不报「还有下一页」：一页有新条目就认为可能还有。
  @override
  bool resolveHasNextPage({
    required bool reported,
    required bool reset,
    required int received,
    required int added,
  }) => added > 0;

  @override
  String keyOf(LnReaderNovelItem item) => item.path;

  @override
  String titleOf(LnReaderNovelItem item) => item.name;

  @override
  Widget buildCover(BuildContext context, LnReaderNovelItem item) =>
      LnReaderCover(
        url: item.cover,
        site: plugin.site,
        pluginHeaders: _info?.imageHeaders ?? const <String, String>{},
        cloudflare: manager.cloudflare,
      );

  @override
  void Function(BuildContext, LnReaderNovelItem)? get openDetail =>
      _openDetails;

  void _openDetails(BuildContext context, LnReaderNovelItem item) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => LnReaderNovelDetailPage(
          manager: manager,
          plugin: plugin,
          item: item,
          imageHeaders: _info?.imageHeaders ?? const <String, String>{},
        ),
      ),
    );
  }

  @override
  Widget buildVerifyAction(
    BuildContext context, {
    required Object? error,
    required Future<void> Function() onVerified,
  }) => LnReaderCloudflareAction(
    cloudflare: manager.cloudflare,
    pluginId: plugin.id,
    onVerified: () => unawaited(onVerified()),
  );
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
      child: const Center(child: FushiIcon(Icons.menu_book_outlined, size: 36)),
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
    return FushiAlertDialog(
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
      LnReaderFilterType.picker => FushiDropdownButtonFormField<String>(
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
      LnReaderFilterType.text => FushiTextFormFieldControl(
        key: ValueKey<String>('novel_filter_${filter.key}'),
        initialValue: filter.value as String,
        decoration: InputDecoration(labelText: filter.label),
        onChanged: (String value) => _set(index, value),
      ),
      LnReaderFilterType.toggle => FushiSwitchListTile.adaptive(
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
            FushiFilterChip(
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
              FushiFilterChip(
                label: Text(option.label),
                selected:
                    include.contains(option.value) ||
                    exclude.contains(option.value),
                // 排除态交给共享组件：MD3 errorContainer 底 + 减号；Apple 中性灰底
                // + destructive 减号。
                tone: exclude.contains(option.value)
                    ? FushiFilterChipTone.exclude
                    : FushiFilterChipTone.include,
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
