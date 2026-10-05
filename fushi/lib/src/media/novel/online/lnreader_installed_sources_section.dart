import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/online/installed_online_source_row.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';

/// 小说在线源列表：书的「来源」页签正文。
///
/// 行结构与漫画 / 视频的 `MihonInstalledSourcesSection` 一致（同一个
/// [InstalledOnlineSourceRow]）：启停开关、标题、语言 tag · 站点；行尾「⋯」菜单
/// （置顶 / 上移 / 下移 / 清数据）——LNReader 插件没有偏好面，所以没有常驻的
/// 「来源偏好」按钮。置顶源单独成组排在上方，两组各自组内可拖拽重排；顶部一条
/// 搜索框 + 状态 / 语言筛选 chip。LNReader 一个插件就是一个源，所以这里的行就是
/// 已装插件。点已启用的行进该源的浏览页。
///
/// `build` 返回 **sliver**。
class LnReaderInstalledSourcesSection extends StatefulWidget {
  const LnReaderInstalledSourcesSection({
    required this.manager,
    required this.onOpenSource,
    super.key,
  });

  final LnReaderManager manager;
  final void Function(LnReaderInstalledPlugin plugin) onOpenSource;

  @override
  State<LnReaderInstalledSourcesSection> createState() =>
      _LnReaderInstalledSourcesSectionState();
}

class _LnReaderInstalledSourcesSectionState
    extends State<LnReaderInstalledSourcesSection> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// 状态 / 语言筛选（只影响显示）。
  OnlineSourceStatusFilter _status = OnlineSourceStatusFilter.all;
  String? _language;

  /// 拖拽落点后、回写完成前的乐观顺序（插件 id）；null = 用 manager 的。
  List<String>? _pendingOrder;

  /// 读盘完成前列表恒空，显示骨架而不是「还没有小说源」。
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_changed);
    unawaited(
      widget.manager.initialise().whenComplete(() {
        if (mounted) setState(() => _ready = true);
      }),
    );
  }

  @override
  void didUpdateWidget(covariant LnReaderInstalledSourcesSection oldWidget) {
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

  Future<void> _clearData(LnReaderInstalledPlugin plugin) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.mihon_source_clear_data,
      message: t.novel_source_clear_data_hint,
      icon: FushiIcons.deleteSweep,
      confirmLabel: t.dialog_clear,
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await widget.manager.clearData(plugin);
    } on Object catch (error, stack) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(
            error,
            logTag: 'LnReaderInstalledSources.clearData',
            stackTrace: stack,
          ),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  /// 当前显示用的完整顺序（见 [_pendingOrder]）。
  List<LnReaderInstalledPlugin> _orderedPlugins() {
    final List<LnReaderInstalledPlugin> plugins = widget.manager.installed;
    final List<String>? pending = _pendingOrder;
    if (pending == null) return plugins;
    final Map<String, LnReaderInstalledPlugin> byId =
        <String, LnReaderInstalledPlugin>{
          for (final LnReaderInstalledPlugin plugin in plugins)
            plugin.id: plugin,
        };
    final Set<String> listed = pending.toSet();
    return <LnReaderInstalledPlugin>[
      for (final String id in pending)
        if (byId[id] case final LnReaderInstalledPlugin plugin) plugin,
      for (final LnReaderInstalledPlugin plugin in plugins)
        if (!listed.contains(plugin.id)) plugin,
    ];
  }

  /// 把一组（置顶组 / 其余组）的新顺序拼回完整列表（置顶组在前）并回写。
  Future<void> _reorderGroup(
    List<LnReaderInstalledPlugin> group, {
    required bool pinned,
  }) async {
    final List<LnReaderInstalledPlugin> otherGroup = <LnReaderInstalledPlugin>[
      for (final LnReaderInstalledPlugin plugin in _orderedPlugins())
        if (plugin.pinned != pinned) plugin,
    ];
    final List<String> ids = <String>[
      for (final LnReaderInstalledPlugin plugin
          in pinned
              ? <LnReaderInstalledPlugin>[...group, ...otherGroup]
              : <LnReaderInstalledPlugin>[...otherGroup, ...group])
        plugin.id,
    ];
    setState(() => _pendingOrder = ids);
    try {
      await widget.manager.reorder(ids);
    } on Object catch (error, stack) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(
            error,
            logTag: 'LnReaderInstalledSources.reorder',
            stackTrace: stack,
          ),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _pendingOrder = null);
    }
  }

  /// 菜单里的「上移 / 下移」：与拖拽同一条回写路径，只在本组内挪一格。
  Future<void> _moveWithinGroup(
    LnReaderInstalledPlugin plugin,
    List<LnReaderInstalledPlugin> group,
    int delta,
  ) async {
    final int index = group.indexWhere(
      (LnReaderInstalledPlugin e) => e.id == plugin.id,
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= group.length) return;
    final List<LnReaderInstalledPlugin> reordered =
        List<LnReaderInstalledPlugin>.of(group);
    final LnReaderInstalledPlugin moved = reordered.removeAt(index);
    reordered.insert(target, moved);
    await _reorderGroup(reordered, pinned: plugin.pinned);
  }

  bool get _narrowed =>
      _searchQuery.trim().isNotEmpty ||
      _status != OnlineSourceStatusFilter.all ||
      _language != null;

  List<LnReaderInstalledPlugin> _visible(List<LnReaderInstalledPlugin> rows) =>
      filterByMediaSearch<LnReaderInstalledPlugin>(
            rows,
            _searchQuery,
            (LnReaderInstalledPlugin plugin) => <String>[
              plugin.name,
              plugin.lang,
              plugin.id,
            ],
          )
          .where(
            (LnReaderInstalledPlugin plugin) => matchesOnlineSourceFilter(
              enabled: plugin.enabled,
              language: plugin.lang,
              status: _status,
              languageFilter: _language,
            ),
          )
          .toList();

  Widget _buildSearchField() => FushiSearchBar(
    fieldKey: const ValueKey<String>('novel_sources_search_field'),
    controller: _searchController,
    hintText: t.mihon_sources_search_hint,
    onQueryChanged: (String value) => setState(() => _searchQuery = value),
  );

  @override
  Widget build(BuildContext context) {
    final List<LnReaderInstalledPlugin> all = _orderedPlugins();
    final bool narrowed = _narrowed;
    final List<LnReaderInstalledPlugin> pinnedAll = <LnReaderInstalledPlugin>[
      for (final LnReaderInstalledPlugin plugin in all)
        if (plugin.pinned) plugin,
    ];
    final List<LnReaderInstalledPlugin> restAll = <LnReaderInstalledPlugin>[
      for (final LnReaderInstalledPlugin plugin in all)
        if (!plugin.pinned) plugin,
    ];
    final List<LnReaderInstalledPlugin> pinned = narrowed
        ? _visible(pinnedAll)
        : pinnedAll;
    final List<LnReaderInstalledPlugin> rest = narrowed
        ? _visible(restAll)
        : restAll;
    final bool reorderable = !narrowed;
    final List<String> languages = onlineSourceLanguages(
      all.map((LnReaderInstalledPlugin plugin) => plugin.lang),
    );
    return FushiEntranceScope(
      replayKey: '${_status.name}|$_language|$_ready',
      child: SliverMainAxisGroup(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildSearchField(),
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
              ],
            ),
          ),
          if (all.isEmpty && !_ready)
            const SliverToBoxAdapter(child: InstalledSourcesSkeleton())
          else if (all.isEmpty)
            SliverToBoxAdapter(
              child: FushiPlaceholderMessage(
                icon: FushiIcons.books,
                message: t.novel_online_sources_empty,
              ),
            )
          else if (narrowed && pinned.isEmpty && rest.isEmpty)
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
                child: InstalledSourcesGroup<LnReaderInstalledPlugin>(
                  key: const ValueKey<String>('novel_sources_pinned_group'),
                  header: t.online_sources_pinned_header,
                  items: pinned,
                  keyOf: (LnReaderInstalledPlugin plugin) => plugin.id,
                  reorderable: reorderable,
                  onReorder: (List<LnReaderInstalledPlugin> reordered) =>
                      unawaited(_reorderGroup(reordered, pinned: true)),
                  rowBuilder: _rowBuilder(pinned, reorderable: reorderable),
                ),
              ),
            if (rest.isNotEmpty)
              SliverToBoxAdapter(
                child: InstalledSourcesGroup<LnReaderInstalledPlugin>(
                  key: const ValueKey<String>('novel_sources_all_group'),
                  // 无置顶时整段只有一组，不必再挂小标题。
                  header: pinned.isNotEmpty
                      ? t.online_sources_all_header
                      : null,
                  items: rest,
                  keyOf: (LnReaderInstalledPlugin plugin) => plugin.id,
                  reorderable: reorderable,
                  entranceOffset: pinned.length,
                  onReorder: (List<LnReaderInstalledPlugin> reordered) =>
                      unawaited(_reorderGroup(reordered, pinned: false)),
                  rowBuilder: _rowBuilder(rest, reorderable: reorderable),
                ),
              ),
          ],
        ],
      ),
    );
  }

  InstalledSourceRowBuilder<LnReaderInstalledPlugin> _rowBuilder(
    List<LnReaderInstalledPlugin> group, {
    required bool reorderable,
  }) =>
      (
        BuildContext context,
        LnReaderInstalledPlugin plugin,
        int index,
        int count,
        bool dragEnabled,
      ) => _buildRow(
        plugin,
        group,
        index: index,
        count: count,
        reorderable: reorderable,
        dragEnabled: dragEnabled,
      );

  Widget _buildRow(
    LnReaderInstalledPlugin plugin,
    List<LnReaderInstalledPlugin> group, {
    required int index,
    required int count,
    required bool reorderable,
    required bool dragEnabled,
  }) {
    final LnReaderManager manager = widget.manager;
    final List<OnlineSourceMenuAction> actions = <OnlineSourceMenuAction>[
      OnlineSourceMenuAction(
        label: plugin.pinned ? t.mihon_source_unpin : t.mihon_source_pin,
        icon: plugin.pinned
            ? FushiIcons.filled(FushiIcons.pin)
            : FushiIcons.pin,
        onTap: () => unawaited(manager.setPinned(plugin, !plugin.pinned)),
      ),
      if (reorderable) ...<OnlineSourceMenuAction>[
        OnlineSourceMenuAction(
          label: t.mihon_source_move_up,
          icon: FushiIcons.expandLess,
          onTap: index == 0
              ? null
              : () => unawaited(_moveWithinGroup(plugin, group, -1)),
        ),
        OnlineSourceMenuAction(
          label: t.mihon_source_move_down,
          icon: FushiIcons.expandMore,
          onTap: index == count - 1
              ? null
              : () => unawaited(_moveWithinGroup(plugin, group, 1)),
        ),
      ],
      OnlineSourceMenuAction(
        label: t.mihon_source_clear_data,
        icon: FushiIcons.deleteSweep,
        destructive: true,
        onTap: () => unawaited(_clearData(plugin)),
      ),
    ];
    return InstalledOnlineSourceRow(
      index: index,
      count: count,
      rowKey: ValueKey<String>('novel_source_row_${plugin.id}'),
      title: plugin.name,
      enabled: plugin.enabled,
      onEnabledChanged: (bool value) =>
          unawaited(manager.setEnabled(plugin, value)),
      language: plugin.lang,
      detail: mangaSourceHostLabel(plugin.site),
      pinned: plugin.pinned,
      onOpen: () => widget.onOpenSource(plugin),
      menuKey: ValueKey<String>('novel_source_menu_${plugin.id}'),
      menuActions: actions,
      dragEnabled: dragEnabled,
    );
  }
}
