import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_preferences_dialog.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/online/installed_online_source_row.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 扩展提供的在线源列表：「导入」视图「在线源」段的正文，漫画与视频共用。
///
/// 一行一个源（M3E 分段列表行，见 [InstalledOnlineSourceRow]）：启停开关、名称、
/// 语言 tag · 包名；行尾「来源偏好」+「⋯」菜单（登录——宿主持有 cookie 的运行时
/// 才有、置顶、上移 / 下移、清数据）。置顶源单独成组排在上方，两组各自组内可
/// 拖拽重排（批量回写 `sort_order`）。顶部一条搜索框 + 「按下载量排序」+ 状态 /
/// 语言筛选 chip。此前漫画来源页和视频在线源页各抄了一份几乎相同的行（视频那份
/// 少了搜索与排序），2026-09-19 两页统一时收成这一处。
///
/// `build` 返回的是 **sliver**（[SliverMainAxisGroup]），由外层 `CustomScrollView`
/// 直接消费——与同页的扩展目录节同一形态。
class MihonInstalledSourcesSection extends StatefulWidget {
  const MihonInstalledSourcesSection({
    required this.manager,
    super.key,
    this.leading = const <Widget>[],
    this.onOpenSource,
    this.emptyLabel,
  });

  final MihonManager manager;

  /// 排在扩展源之前的内置源行（漫画：mokuro.moe、互联对端）。普通 box widget，
  /// 各自带底部间距；有内置行时扩展源一组挂「全部来源」小标题。
  final List<Widget> leading;

  /// 点行进该源的浏览页；为 null 时行不可点。小说 / 漫画 / 视频三域都传。
  final void Function(MangaOnlineSourceRow source)? onOpenSource;

  /// 一个扩展源都没有时的提示；为 null 不提示（有内置行的域列表不算空）。
  final String? emptyLabel;

  @override
  State<MihonInstalledSourcesSection> createState() =>
      _MihonInstalledSourcesSectionState();
}

class _MihonInstalledSourcesSectionState
    extends State<MihonInstalledSourcesSection> {
  /// 已安装在线源列表的搜索（BUG-2479）：源一多，找「要登录的那一个」得翻半天。
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// 状态 / 语言筛选（只影响显示）。
  OnlineSourceStatusFilter _status = OnlineSourceStatusFilter.all;
  String? _language;

  /// 拖拽落点后、回写完成前的乐观顺序（行身份 [_keyOf]）；null = 用 manager 的。
  List<String>? _pendingOrder;

  /// 每次提交排序意图 +1：只有最新一次意图结束时才撤掉乐观顺序
  /// （HBK-AUDIT-016：先前的保存先完成时不能把显示弹回中间态）。
  int _reorderGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant MihonInstalledSourcesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.manager, widget.manager)) return;
    oldWidget.manager.removeListener(_changed);
    widget.manager.addListener(_changed);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_changed);
    _searchController.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _clearSourceData(MangaOnlineSourceRow source) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.mihon_source_clear_data,
      message: t.mihon_source_clear_data_hint,
      icon: FushiIcons.deleteSweep,
      confirmLabel: t.dialog_clear,
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await widget.manager.clearSourceData(source);
    } on Object catch (error, stack) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(
            error,
            logTag: 'MihonInstalledSources',
            stackTrace: stack,
          ),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  /// 该源能不能在 app 里登录，以及登录页要打开哪个地址。
  ///
  /// 两个条件缺一不可：运行时是「宿主持有 cookie」那一类（桌面 sidecar；Android
  /// 由系统 `CookieManager` 拥有 cookie，不需要也不该走这条），以及该源报出了
  /// 可解析出 host 的 baseUrl（有些源的 baseUrl 是空串或相对地址）。
  Uri? _loginTargetFor(MangaOnlineSourceRow source) => mihonLoginTarget(
    runtime: widget.manager.runtime,
    baseUrl: source.baseUrl,
  );

  Future<void> _openWebLogin(MangaOnlineSourceRow source) async {
    final bool saved = await openMihonWebLogin(
      context,
      runtime: widget.manager.runtime,
      sourceName: source.name,
      baseUrl: source.baseUrl,
    );
    if (!mounted || !saved) return;
    FushiToast.show(msg: t.mihon_source_login_saved);
    // 登录态变了，源的章节归属会跟着变；让下一次进源重新取，而不是继续用锁着的
    // 那份缓存。
    setState(() {});
  }

  void _openPreferences(MangaOnlineSourceRow source) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          MihonPreferencesDialog(manager: widget.manager, source: source),
    );
  }

  /// 「按下载量排序」（BUG-2481）：一次性按扩展下载量重写 sort_order。目录快照
  /// 还没刷出来时提示先刷新仓库，不偷偷按 null 排。
  Future<void> _sortSourcesByDownloads() async {
    try {
      final bool sorted = await widget.manager.sortSourcesByDownloads();
      if (!mounted) return;
      FushiToast.show(
        msg: sorted
            ? t.mihon_sources_sort_by_downloads_done
            : t.mihon_sources_sort_by_downloads_no_data,
        severity: sorted ? ToastSeverity.success : ToastSeverity.warning,
      );
    } on Object catch (error, stack) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(
            error,
            logTag: 'MihonInstalledSources',
            stackTrace: stack,
          ),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  /// 行身份：同一扩展包可提供多个源。
  static String _keyOf(MangaOnlineSourceRow source) =>
      '${source.extensionPackage}#${source.sourceId}';

  /// 当前显示用的完整顺序：拖拽落点后、manager 回写完成前先按用户排出的顺序
  /// 显示（避免松手后先弹回旧序再跳到新序）。
  List<MangaOnlineSourceRow> _orderedSources() {
    final List<MangaOnlineSourceRow> rows = widget.manager.sources;
    final List<String>? pending = _pendingOrder;
    if (pending == null) return rows;
    final Map<String, MangaOnlineSourceRow> byKey =
        <String, MangaOnlineSourceRow>{
          for (final MangaOnlineSourceRow row in rows) _keyOf(row): row,
        };
    final Set<String> listed = pending.toSet();
    return <MangaOnlineSourceRow>[
      for (final String key in pending)
        if (byKey[key] case final MangaOnlineSourceRow row) row,
      for (final MangaOnlineSourceRow row in rows)
        if (!listed.contains(_keyOf(row))) row,
    ];
  }

  /// 把一组（置顶组 / 其余组）的新顺序拼回完整列表（置顶组在前），批量回写
  /// `sort_order`。
  Future<void> _reorderGroup(
    List<MangaOnlineSourceRow> group, {
    required bool pinned,
  }) async {
    final List<MangaOnlineSourceRow> all = _orderedSources();
    final List<MangaOnlineSourceRow> otherGroup = <MangaOnlineSourceRow>[
      for (final MangaOnlineSourceRow row in all)
        if (row.pinned != pinned) row,
    ];
    final List<MangaOnlineSourceRow> full = pinned
        ? <MangaOnlineSourceRow>[...group, ...otherGroup]
        : <MangaOnlineSourceRow>[...otherGroup, ...group];
    final int generation = ++_reorderGeneration;
    setState(() {
      _pendingOrder = <String>[
        for (final MangaOnlineSourceRow row in full) _keyOf(row),
      ];
    });
    try {
      await widget.manager.reorderSources(full);
    } on Object catch (error, stack) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(
            error,
            logTag: 'MihonInstalledSources.reorder',
            stackTrace: stack,
          ),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted && generation == _reorderGeneration) {
        setState(() => _pendingOrder = null);
      }
    }
  }

  /// 菜单里的「上移 / 下移」：与拖拽同一条回写路径，只在本组内挪一格。
  Future<void> _moveWithinGroup(
    MangaOnlineSourceRow source,
    List<MangaOnlineSourceRow> group,
    int delta,
  ) async {
    final int index = group.indexWhere(
      (MangaOnlineSourceRow row) => _keyOf(row) == _keyOf(source),
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= group.length) return;
    final List<MangaOnlineSourceRow> reordered = List<MangaOnlineSourceRow>.of(
      group,
    );
    final MangaOnlineSourceRow moved = reordered.removeAt(index);
    reordered.insert(target, moved);
    await _reorderGroup(reordered, pinned: source.pinned);
  }

  bool get _searching => _searchQuery.trim().isNotEmpty;

  bool get _filtering =>
      _status != OnlineSourceStatusFilter.all || _language != null;

  /// 搜索按名称 / 语言 / 扩展包名匹配，走全应用统一的归一化（不用裸 contains）；
  /// 再叠状态 / 语言筛选。只影响显示。
  List<MangaOnlineSourceRow> _visible(List<MangaOnlineSourceRow> rows) =>
      filterByMediaSearch<MangaOnlineSourceRow>(
            rows,
            _searchQuery,
            (MangaOnlineSourceRow source) => <String>[
              source.name,
              source.language,
              source.extensionPackage,
            ],
          )
          .where(
            (MangaOnlineSourceRow source) => matchesOnlineSourceFilter(
              enabled: source.enabled,
              language: source.language,
              status: _status,
              languageFilter: _language,
            ),
          )
          .toList();

  Widget _buildSearchRow() => Row(
    children: <Widget>[
      Expanded(
        child: FushiSearchBar(
          fieldKey: const ValueKey<String>('mihon_sources_search_field'),
          controller: _searchController,
          hintText: t.mihon_sources_search_hint,
          onQueryChanged: (String value) =>
              setState(() => _searchQuery = value),
        ),
      ),
      const SizedBox(width: 8),
      // 「按下载量排序」（BUG-2481）：M3E tonal 图标按钮。
      FushiIconButtonControl.filledTonal(
        key: const ValueKey<String>('mihon_sources_sort_by_downloads'),
        tooltip: t.mihon_sources_sort_by_downloads,
        onPressed: () => unawaited(_sortSourcesByDownloads()),
        icon: const FushiIcon(FushiIcons.sort),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final List<MangaOnlineSourceRow> all = _orderedSources();
    final List<MangaOnlineSourceRow> pinnedAll = <MangaOnlineSourceRow>[
      for (final MangaOnlineSourceRow row in all)
        if (row.pinned) row,
    ];
    final List<MangaOnlineSourceRow> restAll = <MangaOnlineSourceRow>[
      for (final MangaOnlineSourceRow row in all)
        if (!row.pinned) row,
    ];
    final bool narrowed = _searching || _filtering;
    final List<MangaOnlineSourceRow> pinned = narrowed
        ? _visible(pinnedAll)
        : pinnedAll;
    final List<MangaOnlineSourceRow> rest = narrowed
        ? _visible(restAll)
        : restAll;
    // 筛选后的顺序不是真实顺序：不可拖、菜单里不出上移 / 下移。
    final bool reorderable = !narrowed;
    final String? emptyLabel = widget.emptyLabel;
    final List<String> languages = onlineSourceLanguages(
      all.map((MangaOnlineSourceRow row) => row.language),
    );
    // 无置顶且没有内置行时整段只有一组，不必再挂「全部来源」小标题。
    final bool showAllHeader = pinned.isNotEmpty || widget.leading.isNotEmpty;
    return FushiEntranceScope(
      replayKey: '${_status.name}|$_language',
      child: SliverMainAxisGroup(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildSearchRow(),
                if (all.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  OnlineSourcesFilterBar(
                    status: _status,
                    language: _language,
                    languages: languages,
                    onChanged:
                        (OnlineSourceStatusFilter status, String? language) =>
                            setState(() {
                              _status = status;
                              _language = language;
                            }),
                  ),
                  if (narrowed && all.length > 1)
                    const OnlineSourcesReorderDisabledHint(),
                ],
                const SizedBox(height: 12),
                ...widget.leading,
              ],
            ),
          ),
          if (all.isEmpty && emptyLabel != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.browserExtension,
                  message: emptyLabel,
                ),
              ),
            )
          else if (narrowed && all.isNotEmpty && pinned.isEmpty && rest.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.searchOff,
                  message: t.no_search_results,
                ),
              ),
            )
          else ...<Widget>[
            if (pinned.isNotEmpty)
              SliverToBoxAdapter(
                child: InstalledSourcesGroup<MangaOnlineSourceRow>(
                  key: const ValueKey<String>('mihon_sources_pinned_group'),
                  header: t.online_sources_pinned_header,
                  items: pinned,
                  keyOf: _keyOf,
                  reorderable: reorderable,
                  onReorder: (List<MangaOnlineSourceRow> reordered) =>
                      unawaited(_reorderGroup(reordered, pinned: true)),
                  rowBuilder: _rowBuilder(pinned, reorderable: reorderable),
                ),
              ),
            if (rest.isNotEmpty)
              SliverToBoxAdapter(
                child: InstalledSourcesGroup<MangaOnlineSourceRow>(
                  key: const ValueKey<String>('mihon_sources_all_group'),
                  header: showAllHeader ? t.online_sources_all_header : null,
                  items: rest,
                  keyOf: _keyOf,
                  reorderable: reorderable,
                  entranceOffset: pinned.length,
                  onReorder: (List<MangaOnlineSourceRow> reordered) =>
                      unawaited(_reorderGroup(reordered, pinned: false)),
                  rowBuilder: _rowBuilder(rest, reorderable: reorderable),
                ),
              ),
          ],
        ],
      ),
    );
  }

  InstalledSourceRowBuilder<MangaOnlineSourceRow> _rowBuilder(
    List<MangaOnlineSourceRow> group, {
    required bool reorderable,
  }) =>
      (
        BuildContext context,
        MangaOnlineSourceRow source,
        int index,
        int count,
        bool dragEnabled,
      ) => _buildRow(
        source,
        group,
        index: index,
        count: count,
        reorderable: reorderable,
        dragEnabled: dragEnabled,
      );

  /// 一行：开关 + 名称 + 语言 tag · 包名；行尾「来源偏好」+「⋯」菜单，宽窄同形
  /// （此前宽行铺开六个图标按钮、窄行才收菜单，两种形态各有一套 bug）。
  ///
  /// [group] 是该行所在组（置顶 / 其余）的完整顺序，「上移 / 下移」只在组内挪，
  /// 保留给键盘 / 手柄用户；[reorderable] 为 false（搜索 / 筛选中）时不出排序项。
  Widget _buildRow(
    MangaOnlineSourceRow source,
    List<MangaOnlineSourceRow> group, {
    required int index,
    required int count,
    required bool reorderable,
    required bool dragEnabled,
  }) {
    final MihonManager manager = widget.manager;
    final void Function(MangaOnlineSourceRow source)? open =
        widget.onOpenSource;
    final List<OnlineSourceMenuAction> actions = <OnlineSourceMenuAction>[
      if (_loginTargetFor(source) != null)
        OnlineSourceMenuAction(
          key: ValueKey<String>('mihon_source_login_${source.sourceId}'),
          label: t.mihon_source_login,
          icon: FushiIcons.login,
          onTap: () => unawaited(_openWebLogin(source)),
        ),
      OnlineSourceMenuAction(
        label: source.pinned ? t.mihon_source_unpin : t.mihon_source_pin,
        icon: source.pinned
            ? FushiIcons.filled(FushiIcons.pin)
            : FushiIcons.pin,
        onTap: () => unawaited(
          manager.updateSourceSettings(source, pinned: !source.pinned),
        ),
      ),
      if (reorderable) ...<OnlineSourceMenuAction>[
        OnlineSourceMenuAction(
          label: t.mihon_source_move_up,
          icon: FushiIcons.expandLess,
          onTap: index == 0
              ? null
              : () => unawaited(_moveWithinGroup(source, group, -1)),
        ),
        OnlineSourceMenuAction(
          label: t.mihon_source_move_down,
          icon: FushiIcons.expandMore,
          onTap: index == count - 1
              ? null
              : () => unawaited(_moveWithinGroup(source, group, 1)),
        ),
      ],
      OnlineSourceMenuAction(
        label: t.mihon_source_clear_data,
        icon: FushiIcons.deleteSweep,
        destructive: true,
        onTap: () => unawaited(_clearSourceData(source)),
      ),
    ];
    return InstalledOnlineSourceRow(
      index: index,
      count: count,
      rowKey: ValueKey<String>(
        'mihon_source_row_${source.extensionPackage}_${source.sourceId}',
      ),
      title: source.name,
      enabled: source.enabled,
      onEnabledChanged: (bool value) =>
          unawaited(manager.updateSourceSettings(source, enabled: value)),
      language: source.language,
      detail: source.extensionPackage,
      pinned: source.pinned,
      onOpen: open == null ? null : () => open(source),
      primaryAction: FushiIconButtonControl(
        tooltip: t.mihon_source_preferences,
        onPressed: () => _openPreferences(source),
        icon: const FushiIcon(FushiIcons.settings),
      ),
      menuKey: ValueKey<String>(
        'mihon_source_menu_${source.extensionPackage}_${source.sourceId}',
      ),
      menuActions: actions,
      dragEnabled: dragEnabled,
    );
  }
}
