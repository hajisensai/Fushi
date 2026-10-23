import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_page_common.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi/utils.dart';

/// 书签管理：文件夹层级浏览、新建文件夹、编辑、移动、删除、拖动排序。
class WebBrowserBookmarksPage extends StatefulWidget {
  const WebBrowserBookmarksPage({required this.store, this.onOpen, super.key});

  final WebBrowserStore store;
  final WebBrowserPageOpenCallback? onOpen;

  @override
  State<WebBrowserBookmarksPage> createState() =>
      _WebBrowserBookmarksPageState();
}

enum _BookmarkAction { openNewTab, edit, move, moveUp, moveDown, delete }

/// 移动目标的一项：文件夹（null id = 根目录）+ 缩进层级。
typedef WebBrowserFolderTarget = ({int? id, String title, int depth});

/// 列出可作为 [moving] 移动目标的全部文件夹（根目录在首位，深度优先），
/// 排除 [moving] 自己及其子孙。
Future<List<WebBrowserFolderTarget>> webBrowserBookmarkFolderTargets(
  WebBrowserStore store, {
  required WebBrowserBookmark moving,
  required String rootTitle,
}) async {
  final List<WebBrowserFolderTarget> result = <WebBrowserFolderTarget>[
    (id: null, title: rootTitle, depth: 0),
  ];
  Future<void> walk(int? parentId, int depth) async {
    for (final WebBrowserBookmark b in await store.bookmarks(
      parentId: parentId,
    )) {
      if (!b.isFolder || b.id == moving.id) continue;
      result.add((id: b.id, title: b.title, depth: depth));
      await walk(b.id, depth + 1);
    }
  }

  await walk(null, 1);
  return result;
}

class _WebBrowserBookmarksPageState extends State<WebBrowserBookmarksPage> {
  /// 当前所在文件夹链（空 = 根目录）。
  final List<WebBrowserBookmark> _path = <WebBrowserBookmark>[];
  List<WebBrowserBookmark> _items = const <WebBrowserBookmark>[];
  bool _loading = true;
  int _loadGeneration = 0;
  int _replay = 0;

  int? get _folderId => _path.isEmpty ? null : _path.last.id;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    unawaited(_load(replay: true));
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() => unawaited(_load());

  Future<void> _load({bool replay = false}) async {
    final int generation = ++_loadGeneration;
    final List<WebBrowserBookmark> items = await widget.store.bookmarks(
      parentId: _folderId,
    );
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _items = items;
      _loading = false;
      if (replay) _replay++;
    });
  }

  void _enter(WebBrowserBookmark folder) {
    setState(() => _path.add(folder));
    unawaited(_load(replay: true));
  }

  void _goTo(int depth) {
    if (depth >= _path.length) return;
    setState(() => _path.removeRange(depth, _path.length));
    unawaited(_load(replay: true));
  }

  void _open(Uri url, {bool newTab = false}) {
    final WebBrowserPageOpenCallback? onOpen = widget.onOpen;
    if (onOpen == null) return;
    onOpen(url, newTab: newTab);
    if (!newTab) unawaited(Navigator.of(context).maybePop());
  }

  Future<void> _newFolder() async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.web_browser_bookmark_folder_new,
      labelText: t.web_browser_bookmark_folder_name,
      icon: FushiIcons.folder,
      confirmLabel: t.dialog_create,
    );
    if (name == null) return;
    await widget.store.addFolder(title: name, parentId: _folderId);
  }

  Future<void> _edit(WebBrowserBookmark b) async {
    if (b.isFolder) {
      final String? name = await showFushiTextInputDialog(
        context: context,
        title: t.web_browser_bookmark_folder_rename,
        labelText: t.web_browser_bookmark_folder_name,
        initialValue: b.title,
        icon: FushiIcons.folder,
      );
      if (name == null) return;
      await widget.store.updateBookmark(b.id, title: name);
      return;
    }
    final List<String>? values = await showWebBrowserFormDialog(
      context: context,
      title: t.web_browser_bookmark_edit,
      icon: FushiIcons.bookmark,
      fields: <WebBrowserFormField>[
        WebBrowserFormField(
          label: t.web_browser_bookmark_title_label,
          initialValue: b.title,
          optional: true,
        ),
        WebBrowserFormField(
          label: t.web_browser_site_url,
          initialValue: b.url.toString(),
          keyboardType: TextInputType.url,
          validator: (String v) => parseWebBrowserAddress(v) == null
              ? t.web_browser_site_url_invalid
              : null,
        ),
      ],
    );
    if (values == null) return;
    final Uri? url = parseWebBrowserAddress(values[1]);
    if (url == null) return;
    await widget.store.updateBookmark(
      b.id,
      title: values[0].isEmpty ? url.host : values[0],
      url: url,
    );
  }

  Future<void> _move(WebBrowserBookmark b) async {
    final List<WebBrowserFolderTarget> targets =
        await webBrowserBookmarkFolderTargets(
          widget.store,
          moving: b,
          rootTitle: t.web_browser_bookmarks_title,
        );
    if (!mounted) return;
    final WebBrowserFolderTarget? target =
        await showFushiChoiceDialog<WebBrowserFolderTarget>(
          context: context,
          title: t.web_browser_bookmark_move_title,
          icon: FushiIcons.moveFile,
          selected: targets.firstWhere(
            (WebBrowserFolderTarget f) => f.id == b.parentId,
            orElse: () => targets.first,
          ),
          options: <FushiChoiceOption<WebBrowserFolderTarget>>[
            for (final WebBrowserFolderTarget f in targets)
              FushiChoiceOption<WebBrowserFolderTarget>(
                value: f,
                label: '${'    ' * f.depth}${f.title}',
                icon: f.id == null ? FushiIcons.bookmarks : FushiIcons.folder,
              ),
          ],
        );
    if (target == null || target.id == b.parentId) return;
    await widget.store.updateBookmark(
      b.id,
      parentId: target.id,
      moveToRoot: target.id == null,
    );
  }

  Future<void> _delete(WebBrowserBookmark b) async {
    if (b.isFolder) {
      final bool ok = await showFushiConfirmDialog(
        context: context,
        title: t.web_browser_bookmark_folder_delete_confirm(name: b.title),
        icon: FushiIcons.delete,
        confirmLabel: t.options_delete,
        destructive: true,
      );
      if (!ok) return;
    }
    await widget.store.deleteBookmark(b.id);
  }

  Future<void> _onAction(WebBrowserBookmark b, _BookmarkAction action) async {
    switch (action) {
      case _BookmarkAction.openNewTab:
        final Uri? url = b.url;
        if (url != null) _open(url, newTab: true);
      case _BookmarkAction.edit:
        await _edit(b);
      case _BookmarkAction.move:
        await _move(b);
      case _BookmarkAction.moveUp:
      case _BookmarkAction.moveDown:
        final int from = _items.indexWhere(
          (WebBrowserBookmark x) => x.id == b.id,
        );
        final int to = action == _BookmarkAction.moveUp ? from - 1 : from + 1;
        if (from >= 0 && to >= 0 && to < _items.length) _reorder(from, to);
      case _BookmarkAction.delete:
        await _delete(b);
    }
  }

  void _reorder(int from, int to) {
    if (from == to) return;
    final WebBrowserBookmark moved = _items[from];
    setState(() {
      final List<WebBrowserBookmark> next = <WebBrowserBookmark>[..._items];
      next.removeAt(from);
      next.insert(to, moved);
      _items = next;
    });
    unawaited(widget.store.updateBookmark(moved.id, position: to));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _path.isEmpty,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop && _path.isNotEmpty) _goTo(_path.length - 1);
      },
      child: FushiPageScaffold(
        title: _path.isEmpty ? t.web_browser_bookmarks_title : _path.last.title,
        actions: <Widget>[
          FushiIconButton(
            key: const ValueKey<String>('web_browser_bookmarks_new_folder'),
            icon: FushiIcons.addCircle,
            tooltip: t.web_browser_bookmark_folder_new,
            onTap: () => unawaited(_newFolder()),
          ),
        ],
        body: _loading
            ? const Center(child: FushiCircularProgressIndicator())
            : _buildList(context),
      ),
    );
  }

  Widget _breadcrumbs(BuildContext context) {
    final List<String> names = <String>[
      t.web_browser_bookmarks_title,
      for (final WebBrowserBookmark f in _path) f.title,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < names.length; i++) ...<Widget>[
            if (i > 0) const FushiIcon(FushiIcons.chevronRight, size: 18),
            FushiTextButton(
              key: ValueKey<String>('web_browser_bookmarks_crumb_$i'),
              onPressed: i == names.length - 1 ? null : () => _goTo(i),
              child: Text(names[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    return webBrowserPageListView(
      replayKey: _replay,
      key: const ValueKey<String>('web_browser_bookmarks_list'),
      children: <Widget>[
        if (_path.isNotEmpty) _breadcrumbs(context),
        if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(t.web_browser_bookmarks_empty)),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FushiReorderableColumn(
              itemCount: _items.length,
              useDragHandles: true,
              spacing: fushiGroupedListGap(context),
              keyForIndex: (int index) =>
                  ValueKey<String>('web_browser_bookmark_${_items[index].id}'),
              onReorder: _reorder,
              itemBuilder: (BuildContext context, int index) =>
                  FushiStaggeredEntrance(
                    index: index,
                    child: FushiGroupedListItem(
                      index: index,
                      count: _items.length,
                      includeGap: false,
                      child: _tile(_items[index]),
                    ),
                  ),
            ),
          ),
      ],
    );
  }

  Widget _tile(WebBrowserBookmark b) {
    final Uri? url = b.url;
    return FushiListItem(
      key: ValueKey<String>('web_browser_bookmark_tile_${b.id}'),
      leading: FushiListLeadingIcon(
        b.isFolder ? FushiIcons.folder : FushiIcons.bookmark,
      ),
      title: Text(b.title.isEmpty && url != null ? url.host : b.title),
      subtitle: url == null ? null : Text(webBrowserDisplayUrl(url)),
      subtitleMaxLines: 1,
      onTap: () => url == null ? _enter(b) : _open(url),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiOverflowMenu<_BookmarkAction>(
            key: ValueKey<String>('web_browser_bookmark_menu_${b.id}'),
            tooltip: t.common_more_actions,
            onSelected: (_BookmarkAction a) => unawaited(_onAction(b, a)),
            items: <PopupMenuEntry<_BookmarkAction>>[
              if (url != null && widget.onOpen != null)
                FushiPopupMenuItem<_BookmarkAction>(
                  value: _BookmarkAction.openNewTab,
                  label: t.web_browser_link_open_new_tab,
                  icon: FushiIcons.openInNew,
                ),
              FushiPopupMenuItem<_BookmarkAction>(
                value: _BookmarkAction.edit,
                label: b.isFolder
                    ? t.web_browser_bookmark_folder_rename
                    : t.options_edit,
                icon: FushiIcons.edit,
              ),
              FushiPopupMenuItem<_BookmarkAction>(
                value: _BookmarkAction.move,
                label: t.collection_split_move_to,
                icon: FushiIcons.moveFile,
              ),
              if (_items.length > 1) ...<PopupMenuEntry<_BookmarkAction>>[
                FushiPopupMenuItem<_BookmarkAction>(
                  value: _BookmarkAction.moveUp,
                  label: t.move_up,
                  icon: FushiIcons.expandLess,
                  enabled: _items.first.id != b.id,
                ),
                FushiPopupMenuItem<_BookmarkAction>(
                  value: _BookmarkAction.moveDown,
                  label: t.move_down,
                  icon: FushiIcons.expandMore,
                  enabled: _items.last.id != b.id,
                ),
              ],
              FushiPopupMenuItem<_BookmarkAction>(
                value: _BookmarkAction.delete,
                label: t.options_delete,
                icon: FushiIcons.delete,
              ),
            ],
          ),
          if (_items.length > 1)
            FushiReorderableDragHandle(
              child: Tooltip(
                message: t.web_browser_bookmark_reorder,
                child: const SizedBox(
                  width: kMinInteractiveDimension,
                  height: kMinInteractiveDimension,
                  child: Center(child: FushiDragHandle()),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
