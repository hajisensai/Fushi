import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_preferences_dialog.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/utils.dart';

/// 扩展提供的在线源列表：「导入」视图「在线源」段的正文，漫画与视频共用。
///
/// 一行一个源：启停开关、上下排序、登录（宿主持有 cookie 的运行时才有）、
/// 偏好、清数据、置顶；顶部一条搜索框 + 「按下载量排序」。此前漫画来源页和视频
/// 在线源页各抄了一份几乎相同的行（视频那份少了搜索与排序），2026-09-19 两页
/// 统一时收成这一处。
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
  /// 各自带底部间距。
  final List<Widget> leading;

  /// 点行进该源的浏览页；为 null 时行不可点（漫画从「发现」进源，这里只管设置）。
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
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(t.mihon_source_clear_data),
        content: Text(t.mihon_source_clear_data_hint),
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
      await widget.manager.clearSourceData(source);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
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

  Future<void> _moveSource(MangaOnlineSourceRow source, int delta) async {
    final MihonManager manager = widget.manager;
    final List<MangaOnlineSourceRow> rows = List<MangaOnlineSourceRow>.of(
      manager.sources,
    );
    final int index = rows.indexWhere(
      (MangaOnlineSourceRow row) =>
          row.extensionPackage == source.extensionPackage &&
          row.sourceId == source.sourceId,
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= rows.length) return;
    final MangaOnlineSourceRow other = rows[target];
    await manager.updateSourceSettings(source, sortOrder: other.sortOrder);
    await manager.updateSourceSettings(other, sortOrder: source.sortOrder);
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
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  /// 搜索按名称 / 语言 / 扩展包名匹配，走全应用统一的归一化（不用裸 contains）。
  List<MangaOnlineSourceRow> _visibleSources() =>
      filterByMediaSearch<MangaOnlineSourceRow>(
        widget.manager.sources,
        _searchQuery,
        (MangaOnlineSourceRow source) => <String>[
          source.name,
          source.language,
          source.extensionPackage,
        ],
      );

  Widget _buildSearchField() => TextField(
    key: const ValueKey<String>('mihon_sources_search_field'),
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
    final MihonManager manager = widget.manager;
    final List<MangaOnlineSourceRow> visible = _visibleSources();
    final bool reorderable = _searchQuery.trim().isEmpty;
    final String? emptyLabel = widget.emptyLabel;
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: _buildSearchField()),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey<String>(
                      'mihon_sources_sort_by_downloads',
                    ),
                    tooltip: t.mihon_sources_sort_by_downloads,
                    onPressed: () => unawaited(_sortSourcesByDownloads()),
                    icon: const Icon(Icons.sort),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...widget.leading,
            ],
          ),
        ),
        if (manager.sources.isEmpty && emptyLabel != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(emptyLabel),
            ),
          )
        else
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (BuildContext context, int index) => _buildRow(
              visible[index],
              manager.sources.indexOf(visible[index]),
              reorderable: reorderable,
            ),
          ),
        if (_searchQuery.trim().isNotEmpty &&
            visible.isEmpty &&
            manager.sources.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text(t.no_search_results)),
            ),
          ),
      ],
    );
  }

  /// [index] 是该源在**完整**列表里的位置（排序按钮据此判首尾）；筛选中列表
  /// 顺序已不是真实顺序，[reorderable] 为 false 时不显示排序按钮。
  ///
  /// 动作区按行宽二选一：宽行铺开成图标按钮；窄行（手机竖屏 / 桌面窄栏）收进
  /// 一个溢出菜单——五六个 48dp 的图标按钮排开就是 300dp，390dp 的手机上标题会
  /// 被挤到零宽，行里只剩开关和一排图标（真实像素抓到的形态）。
  Widget _buildRow(
    MangaOnlineSourceRow source,
    int index, {
    required bool reorderable,
  }) {
    final MihonManager manager = widget.manager;
    final void Function(MangaOnlineSourceRow source)? open =
        widget.onOpenSource;
    final List<_SourceAction> actions = <_SourceAction>[
      if (reorderable) ...<_SourceAction>[
        _SourceAction(
          label: t.mihon_source_move_up,
          icon: Icons.keyboard_arrow_up,
          onTap: index == 0 ? null : () => unawaited(_moveSource(source, -1)),
        ),
        _SourceAction(
          label: t.mihon_source_move_down,
          icon: Icons.keyboard_arrow_down,
          onTap: index == manager.sources.length - 1
              ? null
              : () => unawaited(_moveSource(source, 1)),
        ),
      ],
      if (_loginTargetFor(source) != null)
        _SourceAction(
          key: ValueKey<String>('mihon_source_login_${source.sourceId}'),
          label: t.mihon_source_login,
          icon: Icons.login,
          onTap: () => unawaited(_openWebLogin(source)),
        ),
      _SourceAction(
        label: t.mihon_source_preferences,
        icon: Icons.tune,
        onTap: () => _openPreferences(source),
      ),
      _SourceAction(
        label: t.mihon_source_clear_data,
        icon: Icons.delete_sweep_outlined,
        onTap: () => unawaited(_clearSourceData(source)),
      ),
      _SourceAction(
        label: source.pinned ? t.mihon_source_unpin : t.mihon_source_pin,
        icon: source.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        onTap: () => unawaited(
          manager.updateSourceSettings(source, pinned: !source.pinned),
        ),
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
            key: ValueKey<String>(
              'mihon_source_row_${source.extensionPackage}_${source.sourceId}',
            ),
            leading: Switch.adaptive(
              value: source.enabled,
              onChanged: (bool value) => unawaited(
                manager.updateSourceSettings(source, enabled: value),
              ),
            ),
            title: Text(source.name),
            subtitle: Text(
              '${source.language.toUpperCase()} · ${source.extensionPackage}',
            ),
            onTap: open != null && source.enabled ? () => open(source) : null,
            trailing: compact
                ? PopupMenuButton<_SourceAction>(
                    key: ValueKey<String>(
                      'mihon_source_menu_${source.extensionPackage}_${source.sourceId}',
                    ),
                    tooltip: t.common_more_actions,
                    icon: const Icon(Icons.more_vert),
                    onSelected: (_SourceAction action) => action.onTap?.call(),
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<_SourceAction>>[
                          for (final _SourceAction action in actions)
                            PopupMenuItem<_SourceAction>(
                              key: action.key,
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
                          key: action.key,
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

/// 行宽低于此值时动作区收成溢出菜单：开关 + 标题最少留 ~200dp，六个 48dp 的
/// 图标按钮要 288dp，再加卡片内边距。
const double _kInlineActionsMinWidth = 560;

/// 源行的一个动作：宽行画成图标按钮，窄行进溢出菜单，同一份定义。
class _SourceAction {
  const _SourceAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.key,
  });

  final Key? key;
  final String label;
  final IconData icon;

  /// 为 null 表示当前不可用（首行的「上移」、末行的「下移」）。
  final VoidCallback? onTap;
}
