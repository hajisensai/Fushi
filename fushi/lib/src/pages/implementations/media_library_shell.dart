import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
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

  /// 本媒体域的设置。正文投影自全局 settings schema，避免复制第二套配置。
  settings,
}

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
    final int index = widget.views
        .indexWhere((MediaLibraryViewSpec spec) => spec.kind == kind);
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
    setState(() {
      _currentIndex = index;
      _visited.add(index);
    });
  }

  @override
  void didUpdateWidget(MediaLibraryShell oldWidget) {
    super.didUpdateWidget(oldWidget);
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
      // 触屏横滑切到相邻视图，序即 [views] 声明序（与分段条同一份真相）。
      sections: <MediaLibraryViewKind>[
        for (final MediaLibraryViewSpec spec in views) spec.kind,
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
        child: FushiFloatingChromeScope(
          controller: _chrome,
          // 工具栏叠在内容上，收起只滑出画面、不改内容视口高度（滚轮上下「回弹、
          // 滚不动」的根因是收起改了视口高度，BUG-2975，见
          // [FushiFloatingChromeOverlay]）。
          child: FushiFloatingChromeOverlay(
            chrome: FushiFloatingChromeBar(tabs: navigation, slot: _actionsSlot),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: sections,
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

  Widget _buildNavigation(List<MediaLibraryViewSpec> views) {
    final MediaLibraryViewKind selected = views[_currentIndex].kind;
    // 分段条走库页共享的 [LibrarySectionTabs]（内含 [FushiAdjustableSegmented]：
    // 单个焦点停靠点，左右方向键原地切视图，手柄/键盘可达）。
    return LibrarySectionTabs<MediaLibraryViewKind>(
      key: _navigationKey,
      tabs: <LibrarySectionTab<MediaLibraryViewKind>>[
        for (final MediaLibraryViewSpec spec in views)
          LibrarySectionTab<MediaLibraryViewKind>(
            value: spec.kind,
            label: spec.label,
          ),
      ],
      selected: selected,
      onChanged: _select,
      focusIdPrefix: widget.focusIdPrefix,
      floating: true,
    );
  }
}
