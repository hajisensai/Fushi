import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart'
    show FushiHeaderSearchKeys, fushiVisibleHeaderSearch;
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationFromVisibleSubtree;
import 'package:fushi/utils.dart';

/// 库页视图种类：一个顶层 tab 内部的几个平级视图。
///
/// 三个媒体域（书 / 漫画 / 视频）共用同一套导航结构，但**各域只声明自己真正有的
/// 视图**——视频没有在线浏览源就不显示 [browse]，绝不放空壳 tab。
enum MediaLibraryViewKind {
  /// 已入库条目（书架 / 媒体库）。
  library,

  /// 内容发现（书：nyaa / OPDS 等发现源；漫画：AniList 趋势 / 来源热门行 /
  /// 「浏览来源」节）。与「浏览 › 发现」同一组生产发现页。
  discover,

  /// 在线源浏览（书 tab 的统一发现页；视频同位）。**漫画已不再使用**：它的在线
  /// 来源清单已并进 [discover]，两个 tab 的文案都叫「发现」曾让用户分不清
  /// （BUG-1710）。
  browse,

  /// 在线来源：已装扩展提供的在线源（与「浏览 › 来源」同一组件）。
  onlineSources,

  /// 扩展：可装扩展目录与已装扩展管理，仓库挂在页头动作上（与「浏览 › 扩展」
  /// 同一组件）。
  extensions,

  /// 导入：本地扫描根 + 快速导入（漫画另有互联对端）。在线来源 / 扩展是上面
  /// 两个独立视图，不在这里。
  sources,

  /// 「媒体服务器」：用户自己的 Kavita / Audiobookshelf 服务器列表（书 / 漫画域），
  /// 点进某台浏览。与视频域的「媒体服务器」分区共用同一个列表组件。只在配了可用
  /// 服务器时出现，增删服务器时会在视图列表中间出现或消失，所以壳按 **kind**
  /// 而不是按下标记住选中项（见 `didUpdateWidget`）。
  ///
  /// 原先的 `kavita` / `audiobookshelf` 两个视图并进了这里；用户自定义页签顺序里
  /// 存的旧 id（`kavita` / `audiobookshelf`）按「存储里有但此刻不存在的忽略」规则
  /// 自然失效，不需要迁移。
  mediaServers,

  // 「设置」视图已移除（2026-10-09 用户拍板）：它只是全局「设置 › <本域>」分类的
  // 投影，与全局设置、阅读时的设置面板重复。各域设置一律从全局设置进入。
}

/// 库页顶栏的一级分组（2026-10-30 用户拍板「顶部胶囊只剩两个」方案 D）：
///
/// - [library]：「我的」内容——已入库条目与用户自己的媒体服务器；
/// - [online]：去网上找——发现、在线来源、扩展。
///
/// 导入（扫描根 + 快速导入）是低频管理页，不占页签：由工具栏右端的
/// [libraryImportChromeButton] 进入。一级恒为一到两段，任何宽度都放得下；组内
/// 多个视图由顶栏下方的二级胶囊切换。书 / 漫画 / 视频 / 游戏四个库页同一分法。
enum LibrarySectionGroup { library, online }

/// [kind] 所属的一级分组；导入（[MediaLibraryViewKind.sources]）不属于任何组。
LibrarySectionGroup? librarySectionGroupOf(MediaLibraryViewKind kind) =>
    switch (kind) {
      MediaLibraryViewKind.library ||
      MediaLibraryViewKind.mediaServers => LibrarySectionGroup.library,
      MediaLibraryViewKind.discover ||
      MediaLibraryViewKind.browse ||
      MediaLibraryViewKind.onlineSources ||
      MediaLibraryViewKind.extensions => LibrarySectionGroup.online,
      MediaLibraryViewKind.sources => null,
    };

/// 库页工具栏右端的「导入」圆钮：切换型按钮，停在导入页时呈选中态，再点一次
/// 回到之前的视图（四个库页壳共用，见 [LibrarySectionGroup]）。
///
/// 没有导入页、导入是几个零散动作的库页（音乐：加文件夹 / 管理文件夹 / 加光盘 /
/// 读 CD）把 [selected] 恒给 false，[onTap] 里在 [anchorKey] 所在位置弹菜单。
Widget libraryImportChromeButton({
  required bool selected,
  required VoidCallback onTap,
  required String focusIdPrefix,
  GlobalKey? anchorKey,
}) => KeyedSubtree(
  key: anchorKey,
  child: fushiFloatingLeading(
    FushiIconButton(
      key: ValueKey<String>('$focusIdPrefix-import'),
      icon: FushiIcons.libraryAdd,
      tooltip: t.library_view_import,
      selected: selected,
      alwaysVisible: true,
      onTap: onTap,
    ),
  )!,
);

/// 一个视图的声明：显示名 + 内容构建器。
///
/// [builder] 收到的 `navigation` 就是本壳的分段条。**视图必须把它作为自己页头的
/// 自定义主内容**，与右侧动作按钮同一行，而不是由壳在外层再包一层页头——三个库页
/// （书架 / 视频 / 漫画）各自拥有导入 / 合集 / 统计等动作，外层再加页头会形成双层
/// chrome。分段条取代重复的大标题后，所有媒体域的导航与动作都处在同一高度。
class MediaLibraryViewSpec {
  const MediaLibraryViewSpec({
    required this.kind,
    required this.label,
    required this.builder,
    this.handlesChromeInset = false,
  });

  final MediaLibraryViewKind kind;
  final String label;
  final Widget Function(BuildContext context, Widget navigation) builder;

  /// 视图自己的主滚动视图把 [FushiFloatingChromeInset] 加成顶部内边距（内容滚到
  /// 壳的浮动工具栏底下，如书架）。false 时壳把整个视图下移工具栏高度
  /// （[FushiFloatingChromeInsetPadding]），视图不必知道工具栏的存在。
  final bool handlesChromeInset;
}

/// 向壳内子树暴露「切到某个视图」的能力（[InheritedWidget]，不改 builder 签名）。
///
/// 动因：库页空态的引导按钮要能把用户带到「导入」视图（[MediaLibraryViewKind.sources]），
/// 而空态 widget 埋在书架页深处——层层回调穿透会让三个库页壳的构造签名全部膨胀。
/// 子树用 [maybeOf] 取到后调 [select]；不在壳内（书架被独立 push）时拿到 null，
/// 调用方自行回退（如直接开导入对话框）。
class MediaLibraryShellScope extends InheritedWidget {
  const MediaLibraryShellScope({
    required this.kinds,
    required this.select,
    required super.child,
    super.key,
  });

  /// 本壳**真正声明了**哪些视图。各域只声明自己有的东西（见 [MediaLibraryViewKind]），
  /// 所以「壳在」不等于「这个视图在」——判据必须是后者，见 [actionFor]。
  final Set<MediaLibraryViewKind> kinds;

  /// 切到指定视图；壳没有该视图时静默忽略。
  ///
  /// **导航所有权在壳这边**：壳上面压着从壳里推出去的页面（全源搜索页 / 发现详情页）
  /// 时，本方法先把它们弹掉再切视图，调用方不必再遵守「先 pop 再 select」这条口头
  /// 契约——那条契约只在「调用页正好是壳上面唯一一层路由」时才成立，第二个调用点
  /// 就不成立了（BUG-1871）。
  final void Function(MediaLibraryViewKind kind) select;

  /// 切到 [kind] 的动作；本壳没有该视图时返回 null。
  ///
  /// 空态引导按钮的唯一正确判据：[select] 对不存在的视图是静默忽略，拿「壳在不在」
  /// 当判据会渲染出一个点了什么都不发生的按钮。
  VoidCallback? actionFor(MediaLibraryViewKind kind) =>
      kinds.contains(kind) ? () => select(kind) : null;

  static MediaLibraryShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaLibraryShellScope>();

  @override
  bool updateShouldNotify(MediaLibraryShellScope oldWidget) =>
      select != oldWidget.select || !setEquals(kinds, oldWidget.kinds);
}

/// 库页视图导航壳：在一个顶层 tab 内切换 [MediaLibraryViewSpec] 声明的若干视图。
///
/// 设计要点：
/// - **只有一个视图时不显示导航条**（`navigation` 传空占位）。这样「某域暂时没有
///   在线源」不需要在调用侧写条件分支，也不会出现点了没内容的死 tab。
/// - 视图**惰性构建 + 保活**（Offstage + TickerMode），与顶层 tab 的做法同源
///   （`home_page.dart` 的 `_visitedKeepAliveTabs`）：没访问过的视图不构建（在线目录
///   不会因为壳挂载就发网络请求），访问过的切走仍保留滚动位置/搜索词，切回不重建。
/// - 顶部与视频库同一套 M3E 浮动工具栏（2026-10-06「书架 / 漫画 / 游戏库与视频库
///   顶部结构统一」，[FushiFloatingChromeBar]）：外壳大标题下面一行是贴合内容宽的
///   分区页签浮动胶囊 + 右侧同高的悬浮动作组。各视图照旧用 [FushiPageHeader] 声明
///   自己的动作，壳挂一个自己的 [FushiShellActionsSlot]，页头把动作登记进来、由
///   浮动动作组画出；所以视图拿到的 `navigation` 一律是空占位（页签由壳画出）。
///   往下滚收起、往上滚 / 回顶 / 切视图弹回（[FushiFloatingChromeController]）。
class MediaLibraryShell extends StatefulWidget {
  const MediaLibraryShell({
    required this.views,
    required this.focusIdPrefix,
    super.key,
  });

  /// 按显示顺序排列的视图；至少一个。
  final List<MediaLibraryViewSpec> views;

  /// 分段条的焦点 id 前缀（每个域一个，避免多域同时挂载时撞 id）。
  final String focusIdPrefix;

  @override
  State<MediaLibraryShell> createState() => _MediaLibraryShellState();
}

class _MediaLibraryShellState extends State<MediaLibraryShell> {
  int _currentIndex = 0;

  /// 每个一级分组上次停留的视图：点组页签回到组内上次的位置。
  final Map<LibrarySectionGroup, MediaLibraryViewKind> _lastInGroup =
      <LibrarySectionGroup, MediaLibraryViewKind>{};

  /// 进导入页之前停留的视图：再点一次导入钮回到这里。
  MediaLibraryViewKind? _beforeImport;

  /// 已访问过的视图下标（惰性构建 + 保活，见类文档）。
  final Set<int> _visited = <int>{0};

  /// 分段条的唯一身份：它只交给当前视图，切视图时从旧视图的页头挪到新视图的页头。
  /// 壳持有的 [GlobalKey] 让挪位置成为**同一个** State 换父节点，指示条从旧视图
  /// 滑到新视图；否则每次都是以目标下标起步的全新页签，切视图没有任何过渡。
  final GlobalKey _navigationKey = GlobalKey(
    debugLabel: 'media-library-sections',
  );

  /// 浮动工具栏的显隐（滚动驱动）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  /// 视图页头登记动作的槽：由浮动动作组画出（见类注释）。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  @override
  void dispose() {
    _chrome.dispose();
    _actionsSlot.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    // 隐藏的保活视图后台加载 / 横滚卡片行发来的通知不算（后者 controller 内按轴过滤）。
    if (!fushiNotificationFromVisibleSubtree(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  void _select(MediaLibraryViewKind kind) {
    final int index = widget.views.indexWhere(
      (MediaLibraryViewSpec spec) => spec.kind == kind,
    );
    if (index < 0) return;
    // 「回到壳」的导航所有权收在这一处：切视图发生在壳里，壳上面压着的路由不弹掉
    // 用户就什么都看不见。以本壳自己的路由为界一次弹到底，与调用方压了几层无关
    // （全源搜索页从「发现」直接推是一层，从「发现详情页」推是两层）。
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      Navigator.of(context).popUntil((Route<dynamic> above) => above == route);
    }
    if (index == _currentIndex) return;
    // 换了视图，新页面从顶部开始：工具栏回来。
    _chrome.resetToTop();
    final MediaLibraryViewKind previous = widget.views[_currentIndex].kind;
    setState(() {
      _currentIndex = index;
      _visited.add(index);
      final LibrarySectionGroup? group = librarySectionGroupOf(kind);
      if (group != null) _lastInGroup[group] = kind;
      if (kind == MediaLibraryViewKind.sources &&
          previous != MediaLibraryViewKind.sources) {
        _beforeImport = previous;
      }
    });
  }

  @override
  void didUpdateWidget(MediaLibraryShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final List<MediaLibraryViewKind> oldKinds = <MediaLibraryViewKind>[
      for (final MediaLibraryViewSpec spec in oldWidget.views) spec.kind,
    ];
    final List<MediaLibraryViewKind> newKinds = <MediaLibraryViewKind>[
      for (final MediaLibraryViewSpec spec in widget.views) spec.kind,
    ];
    if (!listEquals(oldKinds, newKinds)) {
      // 视图集合变了（在线源下线、Audiobookshelf 登录 / 登出）：选中项和「访问过」
      // 的保活集合都是下标，下标会随中间那一项的出现 / 消失整体错位，必须按 kind
      // 重新定位到新列表里。
      final MediaLibraryViewKind? currentKind = _currentIndex < oldKinds.length
          ? oldKinds[_currentIndex]
          : null;
      final Set<MediaLibraryViewKind> visitedKinds = <MediaLibraryViewKind>{
        for (final int i in _visited)
          if (i < oldKinds.length) oldKinds[i],
      };
      final int current = currentKind == null
          ? -1
          : newKinds.indexOf(currentKind);
      _visited.clear();
      if (current < 0) {
        // 当前视图没了：回到第一个。
        _currentIndex = 0;
        _visited.add(0);
        return;
      }
      _currentIndex = current;
      for (final MediaLibraryViewKind kind in visitedKinds) {
        final int index = newKinds.indexOf(kind);
        if (index >= 0) _visited.add(index);
      }
      _visited.add(current);
      return;
    }
    // 视图集合变短（例如某域的在线源被下线）时把选中项拉回合法范围。
    if (_currentIndex >= widget.views.length) {
      _currentIndex = 0;
      _visited
        ..clear()
        ..add(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<MediaLibraryViewSpec> views = widget.views;
    final Set<MediaLibraryViewKind> kinds = <MediaLibraryViewKind>{
      for (final MediaLibraryViewSpec spec in views) spec.kind,
    };
    if (views.length < 2) {
      return MediaLibraryShellScope(
        kinds: kinds,
        select: _select,
        child: views.first.builder(context, const SizedBox.shrink()),
      );
    }
    final Widget navigation = _buildNavigation(views);
    final Widget sections = SectionSwipeNavigator<MediaLibraryViewKind>(
      // 触屏横滑切到相邻视图，序即页签的视觉序：先「我的」组、再「在线」组，组内
      // 按声明序（与两级页签同一份真相），跨组照样接着滑，首 / 末再往外交给外层
      // 切模块。导入不是页签，只在停在导入页时排在最后（从它滑回相邻视图）。
      sections: <MediaLibraryViewKind>[
        for (final LibrarySectionGroup group in LibrarySectionGroup.values)
          for (final MediaLibraryViewSpec spec in _membersOf(views, group))
            spec.kind,
        if (views[_currentIndex].kind == MediaLibraryViewKind.sources)
          MediaLibraryViewKind.sources,
      ],
      selected: views[_currentIndex].kind,
      onSelect: _select,
      child: Stack(
        children: <Widget>[
          for (int i = 0; i < views.length; i++)
            if (_visited.contains(i))
              Offstage(
                offstage: i != _currentIndex,
                child: TickerMode(
                  enabled: i == _currentIndex,
                  // [Offstage] 只关 Flutter 自己的 hitTest；desktop_drop 是进程级
                  // 全局广播，只按各 drop target 的 `RenderBox.paintBounds` 过滤，
                  // 而隐藏的保活视图仍以完整约束布局（全屏大小），于是**每个访问过
                  // 的子视图都会收到同一次 OS drop**。外层 home-shell 的作用域只
                  // 回答「书/漫画 tab 可见吗」，用户停在同一个 tab 的发现视图时答案
                  // 照样是 true —— 隐藏的书架仍会把拖入的文件夹当漫画导入。
                  // 判据与上面 `offstage:` 用的是同一个表达式，且写成回调、在 drop
                  // 落地那一刻求值。
                  // 隐藏视图不参与焦点遍历与系统返回（HBK-AUDIT-017），判据同
                  // `offstage:`。
                  child: SectionVisibilityScope(
                    visible: i == _currentIndex,
                    child: DropSurfaceScope(
                      isActive: () => i == _currentIndex,
                      // 每个保活视图自己的主滚动控制器：共用 tab 外壳那一个会让
                      // 多个主滚动视图附着同一控制器、Scrollbar 断言。
                      child: SectionPrimaryScrollScope(
                        child: _insetFor(
                          views[i],
                          // 页签由壳的浮动工具栏画出，视图页头的主位留空。
                          views[i].builder(context, const SizedBox.shrink()),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
    // 保留外壳给本 tab 的页面名（页头据它判断「标题已由外壳画出」），只把动作槽
    // 换成壳自己的，动作改由浮动动作组画（与视频库外壳同构）。
    return MediaLibraryShellScope(
      kinds: kinds,
      select: _select,
      child: FushiShellTitleScope(
        title: FushiShellTitleScope.maybeTitleOf(context) ?? '',
        actionsSlot: _actionsSlot,
        child: FushiHeaderSearchKeys(
          // Ctrl+F / `/` 展开当前视图的页头搜索，展开时 Esc 先清空再收起
          // （焦点在页签、动作或内容上都认）。
          resolve: () => fushiVisibleHeaderSearch(_actionsSlot),
          child: FushiFloatingChromeScope(
            controller: _chrome,
            // 工具栏叠在内容上，收起只滑出画面、不改内容视口高度（滚轮上下「回弹、
            // 滚不动」的根因是收起改了视口高度，BUG-2975，见
            // [FushiFloatingChromeOverlay]）。
            child: FushiFloatingChromeOverlay(
              chrome: FushiFloatingChromeBar(
                tabs: navigation,
                slot: _actionsSlot,
                trailing: kinds.contains(MediaLibraryViewKind.sources)
                    ? libraryImportChromeButton(
                        selected:
                            views[_currentIndex].kind ==
                            MediaLibraryViewKind.sources,
                        onTap: _toggleImport,
                        focusIdPrefix: widget.focusIdPrefix,
                      )
                    : null,
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                // 二级胶囊行叠在页面上、与顶栏同一份显隐（嵌套的
                // [FushiFloatingChromeOverlay] 读同一个作用域，视图的顶部让位
                // 自动累加两行）；当前组只有一个视图（或在导入页）时不占高度。
                child: FushiFloatingChromeOverlay(
                  chrome: _buildSubNavigation(context, views),
                  child: sections,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 不自己处理工具栏让位的视图整体下移工具栏高度（见
  /// [MediaLibraryViewSpec.handlesChromeInset]）。
  Widget _insetFor(MediaLibraryViewSpec spec, Widget view) =>
      spec.handlesChromeInset
      ? view
      : FushiFloatingChromeInsetPadding(child: view);

  /// 导入钮：不在导入页时进去，在导入页时回到进来前的视图。
  void _toggleImport() {
    final MediaLibraryViewKind current = widget.views[_currentIndex].kind;
    if (current != MediaLibraryViewKind.sources) {
      _select(MediaLibraryViewKind.sources);
      return;
    }
    _select(_beforeImport ?? widget.views.first.kind);
  }

  /// [group] 内按声明序的视图。
  List<MediaLibraryViewSpec> _membersOf(
    List<MediaLibraryViewSpec> views,
    LibrarySectionGroup group,
  ) => <MediaLibraryViewSpec>[
    for (final MediaLibraryViewSpec spec in views)
      if (librarySectionGroupOf(spec.kind) == group) spec,
  ];

  /// 组页签此刻代表的视图：当前就在组内时是当前视图，否则是组内上次停留的
  /// （已下线就退回组内第一个）。
  MediaLibraryViewKind _groupValue(
    LibrarySectionGroup group,
    List<MediaLibraryViewSpec> members,
    MediaLibraryViewKind selected,
  ) {
    if (librarySectionGroupOf(selected) == group) return selected;
    final MediaLibraryViewKind? last = _lastInGroup[group];
    return members.any((MediaLibraryViewSpec spec) => spec.kind == last)
        ? last!
        : members.first.kind;
  }

  String _groupLabel(
    LibrarySectionGroup group,
    List<MediaLibraryViewSpec> members,
  ) => members.length == 1
      ? members.single.label
      : switch (group) {
          // 「我的」组以库视图自己的名字命名（书架）。
          LibrarySectionGroup.library => members.first.label,
          LibrarySectionGroup.online => t.library_view_online,
        };

  Widget _buildNavigation(List<MediaLibraryViewSpec> views) {
    final MediaLibraryViewKind selected = views[_currentIndex].kind;
    final List<LibrarySectionTab<MediaLibraryViewKind>> tabs =
        <LibrarySectionTab<MediaLibraryViewKind>>[];
    for (final LibrarySectionGroup group in LibrarySectionGroup.values) {
      final List<MediaLibraryViewSpec> members = _membersOf(views, group);
      if (members.isEmpty) continue;
      tabs.add(
        LibrarySectionTab<MediaLibraryViewKind>(
          value: _groupValue(group, members, selected),
          label: _groupLabel(group, members),
          // 组页签的值随组内停留的视图变，顺序身份认组。
          orderId: group.name,
        ),
      );
    }
    // 一级只剩一组（iOS 合规门下没有在线视图）时不画胶囊。
    if (tabs.length < 2) return const SizedBox.shrink();
    // 停在导入页时高亮「我的」组：导入管理的就是本地库。
    final MediaLibraryViewKind shown = librarySectionGroupOf(selected) == null
        ? tabs.first.value
        : selected;
    // 分段条走库页共享的 [LibrarySectionTabs]（内含 [FushiAdjustableSegmented]：
    // 单个焦点停靠点，左右方向键原地切视图，手柄/键盘可达）。
    return LibrarySectionTabs<MediaLibraryViewKind>(
      key: _navigationKey,
      tabs: tabs,
      selected: shown,
      onChanged: _select,
      focusIdPrefix: widget.focusIdPrefix,
      floating: true,
    );
  }

  /// 当前组的二级胶囊（书架 / 媒体服务器；发现 / 来源 / 扩展）；组内只有一个
  /// 视图或停在导入页时为空。
  Widget _buildSubNavigation(
    BuildContext context,
    List<MediaLibraryViewSpec> views,
  ) {
    final MediaLibraryViewKind selected = views[_currentIndex].kind;
    final LibrarySectionGroup? group = librarySectionGroupOf(selected);
    if (group == null) return const SizedBox.shrink();
    final List<MediaLibraryViewSpec> members = _membersOf(views, group);
    if (members.length < 2) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      // 与顶栏胶囊、页面内容同一条页边；顶上 8 + 顶栏底边 4 = 两级页签之间 12
      // （同浏览页二级内容域）。
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: LibrarySectionTabs<MediaLibraryViewKind>(
          // 换组即换一份页签（段数与段值都变），不复用旧 controller。
          key: ValueKey<LibrarySectionGroup>(group),
          tabs: <LibrarySectionTab<MediaLibraryViewKind>>[
            for (final MediaLibraryViewSpec spec in members)
              LibrarySectionTab<MediaLibraryViewKind>(
                value: spec.kind,
                label: spec.label,
              ),
          ],
          selected: selected,
          onChanged: _select,
          focusIdPrefix: '${widget.focusIdPrefix}-${group.name}',
          secondary: true,
          floating: true,
          // 反馈 ndQ5eXLcqp：长按 / 右键页签栏自定义页签顺序。一级恒为两组，排序
          // 落在组内的二级胶囊上（书 / 漫画各组各一份）。
          orderKey: '${widget.focusIdPrefix}-${group.name}',
        ),
      ),
    );
  }
}
