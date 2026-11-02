import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_layout.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_routes.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_favicon.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/utils.dart' show WheelToHorizontalScroll;
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

/// 侧边栏 / 顶部标签栏 / 标签页网格共用的标签操作。
@immutable
class WebBrowserTabCallbacks {
  const WebBrowserTabCallbacks({
    required this.isActive,
    required this.onSelect,
    required this.onClose,
    required this.onNewTab,
    required this.onContextMenu,
    required this.onReorder,
    this.onNewIncognitoTab,
  });

  final bool Function(WebBrowserTab tab) isActive;
  final ValueChanged<WebBrowserTab> onSelect;
  final ValueChanged<WebBrowserTab> onClose;
  final VoidCallback onNewTab;

  /// null = 本平台不支持无痕。
  final VoidCallback? onNewIncognitoTab;

  /// 标签区域右键 / 长按（[globalPosition] 定位菜单）。
  final void Function(WebBrowserTab tab, Offset globalPosition) onContextMenu;

  /// 标签重排，沿 SDK `ReorderableList` 口径：[newIndex] 是**移除前**的插入点
  /// （往后拖时比最终下标大 1）。本文件的重排件给出的是最终下标，经
  /// [_reorderToListIndex] 换算后再交给这里。
  final void Function(int oldIndex, int newIndex) onReorder;
}

/// [FushiReorderableColumn] / [FushiReorderableRow] 的「最终下标 to」换成
/// [WebBrowserTabCallbacks.onReorder] 的 `ReorderableList` 口径（移除前插入点）。
int _reorderToListIndex(int from, int to) => to > from ? to + 1 : to;

Color _chromeColor(BuildContext context) => isGlassDesign(context)
    ? appleColorsOf(context).secondaryGroupedBackground
    : Theme.of(context).colorScheme.surfaceContainer;

Color _selectedColor(BuildContext context) => isGlassDesign(context)
    ? appleColorsOf(context).accent.withValues(alpha: 0.16)
    : Theme.of(context).colorScheme.secondaryContainer;

Color _dimColor(BuildContext context) => isGlassDesign(context)
    ? appleColorsOf(context).secondaryLabel
    : Theme.of(context).colorScheme.onSurfaceVariant;

Widget _favicon(WebBrowserTab tab, {double size = 20}) => tab.incognito
    ? SizedBox.square(
        dimension: size,
        child: FushiIcon(FushiIcons.incognito, size: size * 0.9),
      )
    : WebBrowserFavicon(
        url: tab.url,
        title: tab.displayTitle,
        faviconUrl: tab.faviconUrl,
        size: size,
      );

String _tabLabel(WebBrowserTab tab) {
  final String title = tab.displayTitle;
  return title.isEmpty ? t.web_browser_tab_new : title;
}

/// 插入时从零宽 / 零高长出来（标签增删的尺寸过渡）。
class _GrowIn extends StatefulWidget {
  const _GrowIn({required this.child, this.axis = Axis.vertical});

  final Widget child;
  final Axis axis;

  @override
  State<_GrowIn> createState() => _GrowInState();
}

class _GrowInState extends State<_GrowIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isDismissed && !_c.isAnimating) {
      _c.duration = fushiMotionDuration(context, FushiMotion.medium);
      // 拖拽浮层里的副本（FushiEntranceScope(enabled: false)）是已可见标签的复制，
      // 直接显示终态，不从零宽长出来。
      if (_c.duration == Duration.zero ||
          !FushiEntranceScope.enabledOf(context)) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: CurvedAnimation(parent: _c, curve: FushiMotion.enter),
    axis: widget.axis,
    axisAlignment: -1,
    child: FadeTransition(opacity: fushiUnitClamped(_c), child: widget.child),
  );
}

/// 一个标签的指针手势：右键（或用户在快捷键里改绑的「打开菜单」键，经
/// [ContextMenuTrigger]）/ 长按开菜单；中键单击关闭（与 Chrome / Edge 一致）。
Widget _tabGestures({
  required WebBrowserTab tab,
  required WebBrowserTabCallbacks callbacks,
  required Widget child,
}) => ContextMenuTrigger(
  onInvoke: (Offset p) => callbacks.onContextMenu(tab, p),
  child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTertiaryTapUp: (TapUpDetails _) => callbacks.onClose(tab),
    onLongPressStart: (LongPressStartDetails d) =>
        callbacks.onContextMenu(tab, d.globalPosition),
    child: child,
  ),
);

// ── 顶部标签栏 ─────────────────────────────────────────────────────────

/// 地址栏上方一排 36dp 横向标签：宽度自适应（120..220）、放不下时横向滚动、末尾 +。
///
/// 桌面自绘标题栏下（[inCaption]）它就是标题栏那一行（Chrome / Edge 式）：
/// 左右让开窗口按钮 / 红绿灯（[captionInsets]），标签之外的空白处拖动窗口
/// （双击最大化，与原标题行一致）。
class WebBrowserTabStrip extends StatelessWidget {
  const WebBrowserTabStrip({
    required this.tabs,
    required this.callbacks,
    this.inCaption = false,
    this.captionInsets = EdgeInsets.zero,
    super.key,
  });

  final List<WebBrowserTab> tabs;
  final WebBrowserTabCallbacks callbacks;
  final bool inCaption;
  final EdgeInsets captionInsets;

  static const double minTabWidth = 120;
  static const double maxTabWidth = 220;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('web-browser-tab-strip'),
      height: kWebBrowserTabStripHeight,
      color: isGlassDesign(context)
          ? appleColorsOf(context).groupedBackground
          : Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8).add(captionInsets),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          // 标题栏模式在 + 后至少留一段拖动空白（标签再多也拖得动窗口）。
          final double dragReserve = inCaption ? _kCaptionDragReserve : 0;
          final double avail = box.maxWidth - 40 - dragReserve;
          final double width = tabs.isEmpty
              ? maxTabWidth
              : (avail / tabs.length).clamp(minTabWidth, maxTabWidth);
          final Widget row = Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Flexible(
                // 鼠标按住标签横拖 = 排序（Chrome / Edge 式），所以不再让鼠标拖动平移
                // 标签栏；平移改走滚轮（纵向滚轮投到横轴）与触屏拖动。
                child: _StripReorderList(
                  tabs: tabs,
                  callbacks: callbacks,
                  tabWidth: width,
                ),
              ),
              FushiIconButton(
                key: const ValueKey<String>('web-browser-strip-new-tab'),
                tooltip: t.web_browser_tab_new,
                icon: FushiIcons.add,
                size: 18,
                padding: const EdgeInsets.all(6),
                onTap: callbacks.onNewTab,
              ),
              SizedBox(width: dragReserve),
            ],
          );
          if (!inCaption) return row;
          // 拖动区垫在整行底下：Row 的空白（含 + 后的保留段）不吃命中，落到这里；
          // 标签与按钮照常在上层接住点击。
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const Positioned.fill(
                child: DragToMoveArea(
                  key: ValueKey<String>('web-browser-strip-drag'),
                  child: SizedBox.expand(),
                ),
              ),
              row,
            ],
          );
        },
      ),
    );
  }
}

/// 标签栏的横向可排序列表（[FushiReorderableRow]：浮层画在列表自身 Stack 里、
/// 指针经 globalToLocal 消掉祖先缩放，界面大小非 100% 时也不漂移，BUG-778）。
///
/// - 鼠标 / 触控板 / 笔：横拖越过拖动阈值即拾起标签（单击仍是切换，中键关闭、
///   右键菜单不受影响），松手落到新位置。
/// - 触屏：不参与重排——横滑平移标签栏（滚动件默认 dragDevices 含 touch），
///   长按出菜单。
/// - 鼠标平移走滚轮：[WheelToHorizontalScroll] 把纵向滚轮投到横轴。鼠标左键横拖
///   已是重排手势，所以不包 HorizontalDragScrollable（会与重排抢同一个横拖）。
class _StripReorderList extends StatefulWidget {
  const _StripReorderList({
    required this.tabs,
    required this.callbacks,
    required this.tabWidth,
  });

  final List<WebBrowserTab> tabs;
  final WebBrowserTabCallbacks callbacks;
  final double tabWidth;

  @override
  State<_StripReorderList> createState() => _StripReorderListState();
}

class _StripReorderListState extends State<_StripReorderList> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kWebBrowserTabStripHeight,
      child: WheelToHorizontalScroll(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: FushiReorderableRow(
            itemCount: widget.tabs.length,
            keyForIndex: (int i) =>
                ValueKey<String>('strip-${widget.tabs[i].id}'),
            onReorder: (int from, int to) =>
                widget.callbacks.onReorder(from, _reorderToListIndex(from, to)),
            // 触屏长按留给标签菜单、横滑留给平移。
            touchDragEnabled: false,
            feedbackBorderRadius: _kStripTabRadius,
            // 外层定高：FushiReorderableRow 的 Stack 把纵向约束放松成 0..36，不定高时
            // 整个标签只有 30dp、停在顶上，与地址栏之间露出一道缝。
            itemBuilder: (BuildContext context, int i) => SizedBox(
              height: kWebBrowserTabStripHeight,
              child: _GrowIn(
                axis: Axis.horizontal,
                child: SizedBox(
                  width: widget.tabWidth,
                  // 贴底的 Align 必须在 _GrowIn 里面：横向 SizeTransition 纵向撑满且
                  // 按顶对齐（AlignmentDirectional(x, -1)），套在它外面的 Align 无效。
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: _StripTab(
                      tab: widget.tabs[i],
                      callbacks: widget.callbacks,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部标签的上圆角（标签本体与拖拽浮层同形）。
const BorderRadius _kStripTabRadius = BorderRadius.vertical(
  top: Radius.circular(10),
);

/// 标题栏模式下标签栏末尾至少保留的拖窗空白。
const double _kCaptionDragReserve = 48;

class _StripTab extends StatelessWidget {
  const _StripTab({required this.tab, required this.callbacks});

  final WebBrowserTab tab;
  final WebBrowserTabCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tab,
      builder: (BuildContext context, Widget? _) {
        final bool active = callbacks.isActive(tab);
        final ThemeData theme = Theme.of(context);
        return _tabGestures(
          tab: tab,
          callbacks: callbacks,
          child: Semantics(
            selected: active,
            button: true,
            label: _tabLabel(tab),
            child: Material(
              color: active ? _chromeColor(context) : Colors.transparent,
              borderRadius: _kStripTabRadius,
              child: InkWell(
                key: ValueKey<String>('web-browser-strip-tab-${tab.id}'),
                borderRadius: _kStripTabRadius,
                onTap: () => callbacks.onSelect(tab),
                child: SizedBox(
                  height: 30,
                  child: Row(
                    children: <Widget>[
                      const SizedBox(width: 10),
                      _favicon(tab, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _tabLabel(tab),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: active ? null : _dimColor(context),
                          ),
                        ),
                      ),
                      FushiIconButton(
                        tooltip: t.web_browser_tab_close,
                        icon: FushiIcons.close,
                        size: 14,
                        padding: const EdgeInsets.all(4),
                        onTap: () => callbacks.onClose(tab),
                      ),
                      const SizedBox(width: 2),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── 侧边栏 ─────────────────────────────────────────────────────────────

/// 左侧 260dp 页面栏：标签页列表（标题 + 图标 + 关闭，可拖动排序）+ 新建，
/// 下面是书签文件夹 / 历史记录 / 下载入口。
class WebBrowserSidebar extends StatelessWidget {
  const WebBrowserSidebar({
    required this.tabs,
    required this.callbacks,
    required this.store,
    required this.onOpenUrl,
    required this.onOpenPage,
    super.key,
  });

  final List<WebBrowserTab> tabs;
  final WebBrowserTabCallbacks callbacks;
  final WebBrowserStore store;
  final ValueChanged<Uri> onOpenUrl;
  final ValueChanged<WebBrowserDataPage> onOpenPage;

  Widget _header(BuildContext context, String title, {Widget? trailing}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 4, 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: _dimColor(context),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      );

  Widget _entry(
    BuildContext context, {
    required Key key,
    required Widget leading,
    required String label,
    required VoidCallback onTap,
  }) => FushiPressScale(
    child: Material(
      color: Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: key,
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 10),
              SizedBox(width: 22, child: Center(child: leading)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('web-browser-sidebar'),
      color: _chromeColor(context),
      child: SizedBox(
        width: kWebBrowserSidebarWidth,
        child: FushiEntranceScope(
          child: CustomScrollView(
            primary: false,
            slivers: <Widget>[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                sliver: SliverToBoxAdapter(
                  child: _header(
                    context,
                    '${t.web_browser_tab_list_title} · ${tabs.length}',
                    trailing: FushiIconButton(
                      key: const ValueKey<String>(
                        'web-browser-sidebar-new-tab',
                      ),
                      tooltip: t.web_browser_tab_new,
                      icon: FushiIcons.add,
                      size: 18,
                      padding: const EdgeInsets.all(6),
                      onTap: callbacks.onNewTab,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                // 鼠标：拖过阈值即排序；触屏：长按后拖（列表滚动占着竖滑）。
                // 自实现重排件：SDK SliverReorderableList 的 Overlay 代理不认祖先
                // 缩放，界面大小非 100% 时浮层漂移（BUG-778）。
                sliver: SliverToBoxAdapter(
                  child: FushiReorderableColumn(
                    itemCount: tabs.length,
                    keyForIndex: (int i) =>
                        ValueKey<String>('sidebar-${tabs[i].id}'),
                    onReorder: (int from, int to) => callbacks.onReorder(
                      from,
                      _reorderToListIndex(from, to),
                    ),
                    itemBuilder: (BuildContext context, int i) => _GrowIn(
                      child: FushiStaggeredEntrance(
                        index: i,
                        child: _SidebarTab(tab: tabs[i], callbacks: callbacks),
                      ),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Divider(height: 16, indent: 6, endIndent: 6),
                      _header(
                        context,
                        t.web_browser_menu_bookmarks,
                        trailing: FushiIconButton(
                          tooltip: t.web_browser_menu_bookmarks,
                          icon: FushiIcons.chevronRight,
                          size: 18,
                          padding: const EdgeInsets.all(6),
                          onTap: () => onOpenPage(WebBrowserDataPage.bookmarks),
                        ),
                      ),
                      _SidebarBookmarks(
                        store: store,
                        itemBuilder:
                            (BuildContext context, WebBrowserBookmark b) =>
                                _entry(
                                  context,
                                  key: ValueKey<String>(
                                    'web-browser-sidebar-bookmark-${b.id}',
                                  ),
                                  leading: b.isFolder
                                      ? FushiIcon(
                                          FushiIcons.folder,
                                          size: 20,
                                          color: _dimColor(context),
                                        )
                                      : WebBrowserFavicon(
                                          url: b.url,
                                          title: b.title,
                                          size: 18,
                                        ),
                                  label: b.title.isEmpty
                                      ? (b.url?.host ?? '')
                                      : b.title,
                                  onTap: () => b.isFolder
                                      ? onOpenPage(WebBrowserDataPage.bookmarks)
                                      : onOpenUrl(b.url!),
                                ),
                      ),
                      const Divider(height: 16, indent: 6, endIndent: 6),
                      _entry(
                        context,
                        key: const ValueKey<String>(
                          'web-browser-sidebar-history',
                        ),
                        leading: FushiIcon(
                          FushiIcons.history,
                          size: 20,
                          color: _dimColor(context),
                        ),
                        label: t.web_browser_menu_history,
                        onTap: () => onOpenPage(WebBrowserDataPage.history),
                      ),
                      _entry(
                        context,
                        key: const ValueKey<String>(
                          'web-browser-sidebar-downloads',
                        ),
                        leading: FushiIcon(
                          FushiIcons.download,
                          size: 20,
                          color: _dimColor(context),
                        ),
                        label: t.web_browser_menu_downloads,
                        onTap: () => onOpenPage(WebBrowserDataPage.downloads),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 侧边栏里根目录的书签 / 文件夹（最多 12 条）。数据只在挂载与 store 变化时读，
/// 不随壳的每次重建（加载进度）去查库。
class _SidebarBookmarks extends StatefulWidget {
  const _SidebarBookmarks({required this.store, required this.itemBuilder});

  final WebBrowserStore store;
  final Widget Function(BuildContext context, WebBrowserBookmark bookmark)
  itemBuilder;

  @override
  State<_SidebarBookmarks> createState() => _SidebarBookmarksState();
}

class _SidebarBookmarksState extends State<_SidebarBookmarks> {
  List<WebBrowserBookmark> _items = const <WebBrowserBookmark>[];
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(_SidebarBookmarks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_load);
      widget.store.addListener(_load);
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    List<WebBrowserBookmark> items;
    try {
      items = await widget.store.bookmarks();
    } on Object {
      items = const <WebBrowserBookmark>[];
    }
    if (!mounted || generation != _generation) return;
    setState(() => _items = items.take(12).toList(growable: false));
  }

  /// 拖动排序：列出的是根目录按 position 排好的前几条，下标即同级位置。
  void _reorder(int from, int to) {
    if (from == to) return;
    final WebBrowserBookmark moved = _items[from];
    setState(() {
      _items = <WebBrowserBookmark>[..._items]
        ..removeAt(from)
        ..insert(to, moved);
    });
    unawaited(widget.store.updateBookmark(moved.id, position: to));
  }

  @override
  Widget build(BuildContext context) => FushiReorderableColumn(
    itemCount: _items.length,
    keyForIndex: (int i) =>
        ValueKey<String>('web-browser-sidebar-bookmark-row-${_items[i].id}'),
    onReorder: _reorder,
    itemBuilder: (BuildContext context, int i) =>
        widget.itemBuilder(context, _items[i]),
  );
}

class _SidebarTab extends StatelessWidget {
  const _SidebarTab({required this.tab, required this.callbacks});

  final WebBrowserTab tab;
  final WebBrowserTabCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tab,
      builder: (BuildContext context, Widget? _) {
        final bool active = callbacks.isActive(tab);
        return _tabGestures(
          tab: tab,
          callbacks: callbacks,
          child: FushiHoverLift(
            scale: 1.01,
            builder: (BuildContext context, bool hovering) => Semantics(
              selected: active,
              button: true,
              label: _tabLabel(tab),
              child: Material(
                color: active ? _selectedColor(context) : Colors.transparent,
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: ValueKey<String>('web-browser-sidebar-tab-${tab.id}'),
                  onTap: () => callbacks.onSelect(tab),
                  child: SizedBox(
                    height: 40,
                    child: Row(
                      children: <Widget>[
                        const SizedBox(width: 10),
                        _favicon(tab),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _tabLabel(tab),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                        ),
                        FushiIconButton(
                          tooltip: t.web_browser_tab_close,
                          icon: FushiIcons.close,
                          size: 16,
                          padding: const EdgeInsets.all(6),
                          onTap: () => callbacks.onClose(tab),
                        ),
                        const SizedBox(width: 2),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── 标签页网格（竖屏） ─────────────────────────────────────────────────

/// 竖屏窄窗口的全屏标签页网格：缩略卡片（标题 + 图标 + 域名，有截图用截图、
/// 没有用色块），关闭、新建，无痕卡片深色区分。
class WebBrowserTabGrid extends StatelessWidget {
  const WebBrowserTabGrid({
    required this.tabs,
    required this.callbacks,
    required this.thumbnails,
    required this.onDone,
    super.key,
  });

  final List<WebBrowserTab> tabs;
  final WebBrowserTabCallbacks callbacks;

  /// 标签页 id → 截图（PNG）。
  final Map<String, Uint8List> thumbnails;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color bg = glass
        ? appleColorsOf(context).groupedBackground
        : theme.colorScheme.surface;
    return Material(
      key: const ValueKey<String>('web-browser-tab-grid'),
      color: bg,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 56,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      '${t.web_browser_tab_list_title} · ${tabs.length}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  // 普通新建永远在：不支持无痕的平台（Android）网格里只剩这一个新建入口。
                  FushiIconButton(
                    key: const ValueKey<String>('web-browser-grid-new-tab'),
                    tooltip: t.web_browser_tab_new,
                    icon: FushiIcons.add,
                    onTap: callbacks.onNewTab,
                  ),
                  if (callbacks.onNewIncognitoTab != null)
                    FushiIconButton(
                      key: const ValueKey<String>(
                        'web-browser-grid-new-incognito',
                      ),
                      tooltip: t.web_browser_tab_new_incognito,
                      icon: FushiIcons.incognito,
                      onTap: callbacks.onNewIncognitoTab,
                    ),
                  FushiIconButton(
                    key: const ValueKey<String>('web-browser-grid-done'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    icon: FushiIcons.check,
                    onTap: onDone,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(
              child: tabs.isEmpty
                  ? Center(
                      child: Text(
                        t.web_browser_tab_list_empty,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _dimColor(context),
                        ),
                      ),
                    )
                  : FushiEntranceScope(
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              childAspectRatio: 0.72,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                            ),
                        itemCount: tabs.length,
                        itemBuilder: fushiStaggeredItemBuilder(
                          (BuildContext context, int i) => _GridCard(
                            key: ValueKey<String>('grid-${tabs[i].id}'),
                            tab: tabs[i],
                            callbacks: callbacks,
                            thumbnail: thumbnails[tabs[i].id],
                            onDone: onDone,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridCard extends StatelessWidget {
  const _GridCard({
    required this.tab,
    required this.callbacks,
    required this.thumbnail,
    required this.onDone,
    super.key,
  });

  final WebBrowserTab tab;
  final WebBrowserTabCallbacks callbacks;
  final Uint8List? thumbnail;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: tab,
      builder: (BuildContext context, Widget? _) {
        final bool active = callbacks.isActive(tab);
        final bool dark = tab.incognito;
        final Color card = dark
            ? const Color(0xFF2B2B30)
            : (isGlassDesign(context)
                  ? appleColorsOf(context).secondaryGroupedBackground
                  : theme.colorScheme.surfaceContainerHigh);
        final Color fg = dark ? Colors.white : theme.colorScheme.onSurface;
        final Color accent = isGlassDesign(context)
            ? appleColorsOf(context).accent
            : theme.colorScheme.primary;
        final Uint8List? shot = thumbnail;
        return _tabGestures(
          tab: tab,
          callbacks: callbacks,
          child: FushiPressScale(
            child: Material(
              color: card,
              shape: RoundedRectangleBorder(
                borderRadius: FushiBorderRadius.poster,
                side: active
                    ? BorderSide(color: accent, width: 2)
                    : BorderSide.none,
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey<String>('web-browser-grid-tab-${tab.id}'),
                onTap: () {
                  callbacks.onSelect(tab);
                  onDone();
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      height: 40,
                      child: Row(
                        children: <Widget>[
                          const SizedBox(width: 10),
                          _favicon(tab, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _tabLabel(tab),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: fg,
                              ),
                            ),
                          ),
                          FushiIconButton(
                            tooltip: t.web_browser_tab_close,
                            icon: FushiIcons.close,
                            size: 16,
                            enabledColor: fg,
                            padding: const EdgeInsets.all(6),
                            onTap: () => callbacks.onClose(tab),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: shot != null
                          ? Image.memory(
                              shot,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                              gaplessPlayback: true,
                            )
                          : ColoredBox(
                              color: dark
                                  ? const Color(0xFF1C1C20)
                                  : webBrowserFaviconColorFor(
                                      tab.url?.host ?? tab.id,
                                    ).withValues(alpha: 0.18),
                              child: Center(
                                child: dark
                                    ? FushiIcon(
                                        FushiIcons.incognito,
                                        size: 32,
                                        color: Colors.white70,
                                      )
                                    : _favicon(tab, size: 36),
                              ),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                      child: Text(
                        dark
                            ? t.web_browser_tab_incognito
                            : (tab.url?.host ?? t.web_browser_tab_new),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: dark ? Colors.white70 : _dimColor(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
