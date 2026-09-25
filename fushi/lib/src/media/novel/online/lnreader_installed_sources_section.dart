import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/utils.dart';

/// 小说在线源列表：书的「导入」视图「在线源」段正文。
///
/// 行结构与漫画 / 视频的 `MihonInstalledSourcesSection` 一致：启停开关、标题、
/// 「语言 · 站点」、动作区（上移 / 下移 / 清数据 / 置顶），宽行铺开成图标按钮、
/// 窄行收进溢出菜单；顶部一条搜索框。LNReader 一个插件就是一个源，所以这里的
/// 行就是已装插件。点已启用的行进该源的浏览页。
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

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_changed);
    unawaited(widget.manager.initialise());
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
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(t.mihon_source_clear_data),
        content: Text(t.novel_source_clear_data_hint),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_clear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.manager.clearData(plugin);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  Widget _buildSearchField() => TextField(
    key: const ValueKey<String>('novel_sources_search_field'),
    controller: _searchController,
    decoration: InputDecoration(
      prefixIcon: const Icon(Icons.search),
      hintText: t.mihon_sources_search_hint,
      border: const OutlineInputBorder(),
      suffixIcon: _searchQuery.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
    ),
    onChanged: (String value) => setState(() => _searchQuery = value),
  );

  @override
  Widget build(BuildContext context) {
    final LnReaderManager manager = widget.manager;
    final List<LnReaderInstalledPlugin> all = manager.installed;
    final List<LnReaderInstalledPlugin> visible =
        filterByMediaSearch<LnReaderInstalledPlugin>(
          all,
          _searchQuery,
          (LnReaderInstalledPlugin plugin) => <String>[
            plugin.name,
            plugin.lang,
            plugin.id,
          ],
        );
    final bool reorderable = _searchQuery.trim().isEmpty;
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildSearchField(),
          ),
        ),
        if (all.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(t.novel_online_sources_empty),
            ),
          )
        else
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (BuildContext context, int index) => _buildRow(
              visible[index],
              all.indexOf(visible[index]),
              reorderable: reorderable,
            ),
          ),
        if (_searchQuery.trim().isNotEmpty && visible.isEmpty && all.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text(t.no_search_results)),
            ),
          ),
      ],
    );
  }

  Widget _buildRow(
    LnReaderInstalledPlugin plugin,
    int index, {
    required bool reorderable,
  }) {
    final LnReaderManager manager = widget.manager;
    final List<_SourceAction> actions = <_SourceAction>[
      if (reorderable) ...<_SourceAction>[
        _SourceAction(
          label: t.mihon_source_move_up,
          icon: Icons.keyboard_arrow_up,
          onTap: index == 0 ? null : () => unawaited(manager.move(plugin, -1)),
        ),
        _SourceAction(
          label: t.mihon_source_move_down,
          icon: Icons.keyboard_arrow_down,
          onTap: index == manager.installed.length - 1
              ? null
              : () => unawaited(manager.move(plugin, 1)),
        ),
      ],
      _SourceAction(
        label: t.mihon_source_clear_data,
        icon: Icons.delete_sweep_outlined,
        onTap: () => unawaited(_clearData(plugin)),
      ),
      _SourceAction(
        label: plugin.pinned ? t.mihon_source_unpin : t.mihon_source_pin,
        icon: plugin.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        onTap: () => unawaited(manager.setPinned(plugin, !plugin.pinned)),
      ),
    ];
    return FushiCard(
      margin: EdgeInsets.only(
        bottom: FushiDesignTokens.of(context).spacing.gap,
      ),
      padding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth < _kInlineActionsMinWidth;
          return FushiListItem(
            key: ValueKey<String>('novel_source_row_${plugin.id}'),
            leading: Switch.adaptive(
              value: plugin.enabled,
              onChanged: (bool value) =>
                  unawaited(manager.setEnabled(plugin, value)),
            ),
            title: Text(plugin.name),
            subtitle: Text(
              mangaSourceMetaLine(<String?>[
                plugin.lang,
                mangaSourceHostLabel(plugin.site),
              ]),
            ),
            onTap: plugin.enabled ? () => widget.onOpenSource(plugin) : null,
            trailing: compact
                ? PopupMenuButton<_SourceAction>(
                    key: ValueKey<String>('novel_source_menu_${plugin.id}'),
                    tooltip: t.common_more_actions,
                    icon: const Icon(Icons.more_vert),
                    onSelected: (_SourceAction action) => action.onTap?.call(),
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<_SourceAction>>[
                          for (final _SourceAction action in actions)
                            PopupMenuItem<_SourceAction>(
                              value: action,
                              enabled: action.onTap != null,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(action.icon, size: 20),
                                  const SizedBox(width: 12),
                                  Flexible(child: Text(action.label)),
                                ],
                              ),
                            ),
                        ],
                  )
                : Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      for (final _SourceAction action in actions)
                        IconButton(
                          tooltip: action.label,
                          onPressed: action.onTap,
                          icon: Icon(action.icon),
                        ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

/// 与 Mihon 源行同一阈值：四个 48dp 图标按钮 + 开关 + 标题的最小宽度。
const double _kInlineActionsMinWidth = 480;

class _SourceAction {
  const _SourceAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
}
