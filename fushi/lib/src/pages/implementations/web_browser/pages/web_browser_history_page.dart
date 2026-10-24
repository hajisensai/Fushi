import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_page_common.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/utils.dart';

/// 浏览历史：按日分组、搜索、单删 / 多选删、按时间范围清除。
class WebBrowserHistoryPage extends StatefulWidget {
  const WebBrowserHistoryPage({required this.store, this.onOpen, super.key});

  final WebBrowserStore store;
  final WebBrowserPageOpenCallback? onOpen;

  /// 一次最多列多少条（更早的仍在库里，搜索可以找到）。
  static const int pageLimit = 1000;

  @override
  State<WebBrowserHistoryPage> createState() => _WebBrowserHistoryPageState();
}

enum _EntryAction { openNewTab, copyLink, delete }

/// 按本地日期分组（保持输入顺序，输入已按最近访问倒序）。
List<({DateTime day, List<WebBrowserHistoryEntry> entries})>
groupWebBrowserHistoryByDay(List<WebBrowserHistoryEntry> entries) {
  final List<({DateTime day, List<WebBrowserHistoryEntry> entries})> groups =
      <({DateTime day, List<WebBrowserHistoryEntry> entries})>[];
  for (final WebBrowserHistoryEntry e in entries) {
    final DateTime local = e.lastVisitedAt.toLocal();
    final DateTime day = DateTime(local.year, local.month, local.day);
    if (groups.isNotEmpty && groups.last.day == day) {
      groups.last.entries.add(e);
    } else {
      groups.add((day: day, entries: <WebBrowserHistoryEntry>[e]));
    }
  }
  return groups;
}

class _WebBrowserHistoryPageState extends State<WebBrowserHistoryPage> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<WebBrowserHistoryEntry> _entries = const <WebBrowserHistoryEntry>[];
  final Set<int> _selected = <int>{};
  bool _selecting = false;
  bool _loading = true;
  int _loadGeneration = 0;
  int _replay = 0;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    unawaited(_load(replay: true));
  }

  @override
  void didUpdateWidget(WebBrowserHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
      unawaited(_load(replay: true));
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onStoreChanged() => unawaited(_load());

  Future<void> _load({bool replay = false}) async {
    final int generation = ++_loadGeneration;
    final List<WebBrowserHistoryEntry> entries = await widget.store.history(
      query: _search.text,
      limit: WebBrowserHistoryPage.pageLimit,
    );
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _entries = entries;
      final Set<int> alive = <int>{
        for (final WebBrowserHistoryEntry e in entries) e.id,
      };
      _selected.retainAll(alive);
      _loading = false;
      if (replay) _replay++;
    });
  }

  void _open(Uri url, {bool newTab = false}) {
    final WebBrowserPageOpenCallback? onOpen = widget.onOpen;
    if (onOpen == null) return;
    onOpen(url, newTab: newTab);
    if (!newTab) unawaited(Navigator.of(context).maybePop());
  }

  void _toggle(int id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _setSelecting(bool value) => setState(() {
    _selecting = value;
    _selected.clear();
  });

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final List<int> ids = _selected.toList();
    await widget.store.deleteHistory(ids);
    if (mounted) _setSelecting(false);
  }

  Future<void> _clearRange() async {
    final WebBrowserClearRange? range =
        await showFushiChoiceDialog<WebBrowserClearRange>(
          context: context,
          title: t.web_browser_history_clear,
          icon: FushiIcons.deleteSweep,
          options: <FushiChoiceOption<WebBrowserClearRange>>[
            for (final WebBrowserClearRange r in WebBrowserClearRange.values)
              FushiChoiceOption<WebBrowserClearRange>(value: r, label: r.label),
          ],
        );
    if (range == null || !mounted) return;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.web_browser_history_clear,
      message: t.web_browser_history_clear_confirm,
      icon: FushiIcons.deleteSweep,
      confirmLabel: t.options_delete,
      destructive: true,
    );
    if (!confirmed) return;
    await widget.store.clearHistory(since: range.sinceFrom(DateTime.now()));
  }

  Future<void> _onEntryAction(
    WebBrowserHistoryEntry entry,
    _EntryAction action,
  ) async {
    switch (action) {
      case _EntryAction.openNewTab:
        _open(entry.url, newTab: true);
      case _EntryAction.copyLink:
        await Clipboard.setData(ClipboardData(text: entry.url.toString()));
      case _EntryAction.delete:
        await widget.store.deleteHistory(<int>[entry.id]);
    }
  }

  List<Widget> _actions() {
    if (_selecting) {
      return <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('web_browser_history_select_all'),
          icon: FushiIcons.selectAll,
          tooltip: t.delete_prompt_select_all,
          onTap: () => setState(() {
            _selected.addAll(_entries.map((WebBrowserHistoryEntry e) => e.id));
          }),
        ),
        FushiIconButton(
          key: const ValueKey<String>('web_browser_history_delete_selected'),
          icon: FushiIcons.delete,
          tooltip: t.delete_prompt_delete_selected,
          enabled: _selected.isNotEmpty,
          overflowPriority: 2,
          onTap: () => unawaited(_deleteSelected()),
        ),
        FushiIconButton(
          key: const ValueKey<String>('web_browser_history_select_done'),
          icon: FushiIcons.close,
          tooltip: t.dialog_cancel,
          alwaysVisible: true,
          onTap: () => _setSelecting(false),
        ),
      ];
    }
    return <Widget>[
      FushiIconButton(
        key: const ValueKey<String>('web_browser_history_select'),
        icon: FushiIcons.checklist,
        tooltip: t.batch_select,
        enabled: _entries.isNotEmpty,
        onTap: () => _setSelecting(true),
      ),
      FushiIconButton(
        key: const ValueKey<String>('web_browser_history_clear'),
        icon: FushiIcons.deleteSweep,
        tooltip: t.web_browser_history_clear,
        overflowPriority: 1,
        onTap: () => unawaited(_clearRange()),
      ),
    ];
  }

  String _dayLabel(BuildContext context, DateTime day) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    if (day == today) return t.home_today;
    if (day == today.subtract(const Duration(days: 1))) return t.home_yesterday;
    return MaterialLocalizations.of(context).formatFullDate(day);
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: _selecting
          ? t.batch_selected_count(n: _selected.length)
          : t.web_browser_history_title,
      actions: _actions(),
      body: _loading
          ? const Center(child: FushiCircularProgressIndicator())
          : _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    final List<({DateTime day, List<WebBrowserHistoryEntry> entries})> groups =
        groupWebBrowserHistoryByDay(_entries);
    int order = 0;
    return webBrowserPageListView(
      replayKey: _replay,
      key: const ValueKey<String>('web_browser_history_list'),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: FushiSearchField(
            fieldKey: const ValueKey<String>('web_browser_history_search'),
            controller: _search,
            focusNode: _searchFocus,
            hintText: t.web_browser_history_search_hint,
            onChanged: (_) => unawaited(_load()),
            onSubmitted: (_) => unawaited(_load()),
            onClear: () {
              _search.clear();
              unawaited(_load());
            },
          ),
        ),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(t.web_browser_history_empty)),
          ),
        for (final ({DateTime day, List<WebBrowserHistoryEntry> entries}) g
            in groups) ...<Widget>[
          FushiSectionTitle.group(
            _dayLabel(context, g.day),
            padding: const EdgeInsets.fromLTRB(32, 16, 32, 6),
          ),
          FushiStaggeredEntrance(
            index: order++,
            child: FushiGroupedList(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: <Widget>[
                for (final WebBrowserHistoryEntry e in g.entries) _tile(e),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _tile(WebBrowserHistoryEntry e) {
    final String time = TimeOfDay.fromDateTime(
      e.lastVisitedAt.toLocal(),
    ).format(context);
    final bool selected = _selected.contains(e.id);
    return FushiListItem(
      key: ValueKey<String>('web_browser_history_${e.id}'),
      selected: _selecting && selected,
      leading: _selecting
          ? FushiCheckbox(value: selected, onChanged: (_) => _toggle(e.id))
          : const FushiListLeadingIcon(FushiIcons.globe),
      title: Text(
        e.title.trim().isEmpty ? webBrowserDisplayUrl(e.url) : e.title,
      ),
      subtitle: Text('$time · ${webBrowserDisplayUrl(e.url)}'),
      subtitleMaxLines: 1,
      onTap: () => _selecting ? _toggle(e.id) : _open(e.url),
      trailing: _selecting
          ? null
          : FushiOverflowMenu<_EntryAction>(
              key: ValueKey<String>('web_browser_history_menu_${e.id}'),
              tooltip: t.common_more_actions,
              onSelected: (_EntryAction a) => unawaited(_onEntryAction(e, a)),
              items: <PopupMenuEntry<_EntryAction>>[
                if (widget.onOpen != null)
                  FushiPopupMenuItem<_EntryAction>(
                    value: _EntryAction.openNewTab,
                    label: t.web_browser_link_open_new_tab,
                    icon: FushiIcons.openInNew,
                  ),
                FushiPopupMenuItem<_EntryAction>(
                  value: _EntryAction.copyLink,
                  label: t.web_browser_link_copy,
                  icon: FushiIcons.link,
                ),
                FushiPopupMenuItem<_EntryAction>(
                  value: _EntryAction.delete,
                  label: t.options_delete,
                  icon: FushiIcons.delete,
                ),
              ],
            ),
    );
  }
}
