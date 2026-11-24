import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/pages/shared/fushi_header_search_keys.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart'
    show fushiVisibleHeaderSearch;
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show
        FushiMastheadPalette,
        FushiMastheadPrimaryButton,
        FushiMastheadRole,
        fushiMastheadRoleOf;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_layout.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';

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
}) {
  final Widget button = FushiIconButton(
    key: ValueKey<String>('$focusIdPrefix-import'),
    icon: FushiIcons.libraryAdd,
    tooltip: t.library_view_import,
    selected: selected,
    alwaysVisible: true,
    onTap: onTap,
  );
  return KeyedSubtree(
    key: anchorKey,
    child: Builder(
      // 只在 M3E 外壳里画（Apple 外壳的导入钮是 `AppleLibraryImportButton`，由
      // `AppleLibraryLayout` 画）。页头大字顶栏（重设计外壳）里是主按钮：
      // indicator 底、圆角 20，悬停 / 选中弹到 28；墨水屏是页头圆。
      builder: (BuildContext context) =>
          fushiMastheadRoleOf(context) == FushiMastheadRole.primary
          ? FushiMastheadPrimaryButton(
              selected: selected,
              builder:
                  (
                    BuildContext context,
                    OutlinedBorder shape,
                    FushiMastheadPalette accent,
                    double extent,
                  ) => FushiIconButton(
                    key: ValueKey<String>('$focusIdPrefix-import'),
                    icon: FushiIcons.libraryAdd,
                    tooltip: t.library_view_import,
                    selected: selected,
                    alwaysVisible: true,
                    onTap: onTap,
                    shapeBorder: shape,
                    backgroundColor: accent.indicator,
                    enabledColor: accent.onIndicator,
                    padding: EdgeInsets.all((extent - 24) / 2),
                    constraints: BoxConstraints.tightFor(
                      width: extent,
                      height: extent,
                    ),
                  ),
            )
          : fushiFloatingLeading(button)!,
    ),
  );
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

class _MediaLibraryShellState extends State<MediaLibraryShell>
    with SingleTickerProviderStateMixin {
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

  /// 每个视图**各自一份**浮动工具栏状态（显隐、页头大字的折叠进度、内容是否
  /// 滚到工具区底下），按视图种类存（BUG-4897）。
  ///
  /// 视图是保活的，各自的滚动位置切走再切回原样还在；工具栏状态若全壳共用一份，
  /// 切视图时只能「重置成顶部」——于是切回一个滚到中段的书架，第一帧是展开的
  /// 大号页头压在按旧滚动位置画的内容上，等内容发来版面通知才缩回小号（录屏里
  /// 那一帧）。现在作用域里挂的是**当前视图自己的** controller，切换即换成该视图
  /// 停下时的那份状态，与它的滚动位置天然一致，没有「先错后纠」的帧。
  ///
  /// 种类集合是有限枚举，controller 只在壳卸载时统一释放（视图下线后留着的那一
  /// 份可能还被本帧的作用域引用，不在中途释放）。
  final Map<MediaLibraryViewKind, FushiFloatingChromeController> _chromes =
      <MediaLibraryViewKind, FushiFloatingChromeController>{};

  FushiFloatingChromeController _chromeFor(MediaLibraryViewKind kind) =>
      _chromes.putIfAbsent(kind, FushiFloatingChromeController.new);

  /// 已构建的视图内容，按种类缓存（BUG-4897：切换点下去约 0.5 秒才动）。
  ///
  /// 切视图只是壳自己 setState；以前每次都把**所有**访问过的保活视图重新调一遍
  /// builder、生成新的页面 widget——书架（整页卡片墙）和在线视图都整页重建，
  /// 切换那一帧被拖得很长。视图内容并不依赖「当前选中哪个视图」（可见性经
  /// [SectionVisibilityScope] / [TickerMode] 下发），所以同一份 widget 实例原样
  /// 复用，Flutter 对同一实例直接跳过重建。外部输入变了（父级换了一组视图声明 /
  /// 壳依赖的继承数据变了）才作废重建。
  final Map<MediaLibraryViewKind, Widget> _viewCache =
      <MediaLibraryViewKind, Widget>{};

  /// 切视图的交叉淡入：新视图从透明淡入、刚离开的视图同步淡出，不硬切（设计稿
  /// #manga C2）。减弱动效下时长归零，直接切。
  late final AnimationController _switchFade = AnimationController(
    vsync: this,
    value: 1,
  )..addStatusListener(_onSwitchFadeStatus);
  late final Animation<double> _switchOpacity = CurvedAnimation(
    parent: _switchFade,
    curve: FushiMotion.enter,
  );
  late final Animation<double> _leavingOpacity = ReverseAnimation(
    _switchOpacity,
  );

  /// 交叉淡入期间正在淡出的上一个视图下标；淡入结束（或没有过渡）时为 null。
  ///
  /// 它在过渡期间仍在台上（不 [Offstage]）好画出淡出，但与其它非当前视图一样
  /// 不收指针、不进焦点遍历、不出语义、不跑动画、不收 drop（判据都是
  /// `i == _currentIndex`），只是一张正在褪去的画面。
  int? _leavingIndex;

  void _onSwitchFadeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _leavingIndex == null) return;
    if (!mounted) return;
    setState(() => _leavingIndex = null);
  }

  /// 视图页头登记动作的槽：由浮动动作组画出（见类注释）。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // builder 以壳的 context 构建，读到的继承数据变了就得重建视图。
    _viewCache.clear();
  }

  @override
  void dispose() {
    for (final FushiFloatingChromeController chrome in _chromes.values) {
      chrome.dispose();
    }
    _switchFade.dispose();
    _actionsSlot.dispose();
    super.dispose();
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
    // 目标视图沿用它自己的折叠进度 / 遮罩状态（与它保留的滚动位置一致）；只把
    // 工具栏亮出来——用户刚在工具栏上点了切换，不能一切过去页签就滑走。
    _chromeFor(kind).show();
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    final int previousIndex = _currentIndex;
    if (fade == Duration.zero) {
      _switchFade.value = 1;
    } else {
      _switchFade
        ..duration = fade
        ..forward(from: 0);
    }
    final MediaLibraryViewKind previous = widget.views[_currentIndex].kind;
    setState(() {
      _leavingIndex = fade == Duration.zero ? null : previousIndex;
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
    // 父级重建 = 新的一组视图声明（builder 闭包捕获的数据可能变了）。
    _viewCache.clear();
    final List<MediaLibraryViewKind> oldKinds = <MediaLibraryViewKind>[
      for (final MediaLibraryViewSpec spec in oldWidget.views) spec.kind,
    ];
    final List<MediaLibraryViewKind> newKinds = <MediaLibraryViewKind>[
      for (final MediaLibraryViewSpec spec in widget.views) spec.kind,
    ];
    if (!listEquals(oldKinds, newKinds)) {
      // 淡出中的视图按下标记，视图集合一变下标就不可信：直接收掉这张淡出画面。
      _leavingIndex = null;
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
      _leavingIndex = null;
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
    final MediaLibraryViewKind current = views[_currentIndex].kind;
    final Widget sections = Stack(
      children: <Widget>[
        for (int i = 0; i < views.length; i++)
          if (_visited.contains(i))
            Offstage(
              // 按视图种类认身份：保活视图按下标排，中间冒出新视图（如媒体
              // 服务器）时不带 key 会让后面已保活的视图错位重建、丢 State。
              key: ValueKey<MediaLibraryViewKind>(views[i].kind),
              // 交叉淡入期间刚离开的视图留在台上画淡出（见 [_leavingIndex]）。
              offstage: i != _currentIndex && i != _leavingIndex,
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
                      child: FadeTransition(
                        // 交叉淡入：当前视图淡入、刚离开的视图淡出；其余恒不
                        // 透明（隐藏着也不画）。
                        opacity: i == _currentIndex
                            ? _switchOpacity
                            : i == _leavingIndex
                            ? _leavingOpacity
                            : kAlwaysCompleteAnimation,
                        // 非当前视图不收指针、不出语义：淡出中的那一张虽在台上，
                        // 也只是褪去的画面（隐藏的保活视图本就被 Offstage 挡住）。
                        child: IgnorePointer(
                          ignoring: i != _currentIndex,
                          child: ExcludeSemantics(
                            excluding: i != _currentIndex,
                            child: _chromeFeed(
                              _chromeFor(views[i].kind),
                              _viewFor(views[i]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
    // 保留外壳给本 tab 的页面名（页头据它判断「标题已由外壳画出」），只把动作槽
    // 换成壳自己的，动作改由浮动动作组画（与视频库外壳同构）。
    final bool inImport = current == MediaLibraryViewKind.sources;
    return MediaLibraryShellScope(
      kinds: kinds,
      select: _select,
      // 系统返回键先退出导入页、回到进来前的视图（反馈 Ph8RkXJOWv：用户进了导入
      // 视图不知道怎么退出）。导入页是壳内视图、不是独立路由，不拦的话 Android
      // 返回键直接弹掉首页路由退出 App。只在所在 tab 可见时拦（HBK-AUDIT-017），
      // 与导入钮「再点一次」走同一个回去的入口。
      child: SectionPopScope(
        intercepting: inImport,
        onIntercept: _toggleImport,
        child: FushiShellTitleScope(
          title: FushiShellTitleScope.maybeTitleOf(context) ?? '',
          actionsSlot: _actionsSlot,
          child: FushiHeaderSearchKeys(
            // Ctrl+F / `/` 展开当前视图的页头搜索，展开时 Esc 先清空再收起
            // （焦点在页签、动作或内容上都认）。
            resolve: () => fushiVisibleHeaderSearch(_actionsSlot),
            // 外壳按设计系统分派（M3E 浮动工具栏 / Apple 方案 A），本壳只给
            // spec 与内容。
            child: LibraryLayout<MediaLibraryViewKind>(
              spec: _chromeSpec(views, kinds),
              body: sections,
            ),
          ),
        ),
      ),
    );
  }

  /// 本壳的外壳描述（见 [LibraryChromeSpec]）。
  LibraryChromeSpec<MediaLibraryViewKind> _chromeSpec(
    List<MediaLibraryViewSpec> views,
    Set<MediaLibraryViewKind> kinds,
  ) {
    final MediaLibraryViewKind selected = views[_currentIndex].kind;
    final LibrarySectionGroup? currentGroup = librarySectionGroupOf(selected);
    final List<LibraryChromeGroup<MediaLibraryViewKind>> groups =
        <LibraryChromeGroup<MediaLibraryViewKind>>[];
    for (final LibrarySectionGroup group in LibrarySectionGroup.values) {
      final List<MediaLibraryViewSpec> members = _membersOf(views, group);
      if (members.isEmpty) continue;
      groups.add(
        LibraryChromeGroup<MediaLibraryViewKind>(
          group: group,
          label: _groupLabel(group, members),
          // 组页签的值随组内停留的视图变（顺序身份认组）。
          value: _groupValue(group, members, selected),
          members: <LibrarySectionTab<MediaLibraryViewKind>>[
            for (final MediaLibraryViewSpec spec in members)
              LibrarySectionTab<MediaLibraryViewKind>(
                value: spec.kind,
                label: spec.label,
              ),
          ],
          subFocusIdPrefix: '${widget.focusIdPrefix}-${group.name}',
          // 反馈 ndQ5eXLcqp：长按 / 右键页签栏自定义页签顺序。一级恒为两组，
          // 排序落在组内的二级胶囊上（书 / 漫画各组各一份）。
          orderKey: '${widget.focusIdPrefix}-${group.name}',
        ),
      );
    }
    // 一级只剩一组（iOS 合规门下没有在线视图）时页签位置改放标题。标题是外壳
    // 给本 tab 的页面名（漫画 / 书架），不是组名：「我的」组以库视图命名（漫画
    // 库也叫「书架」），当页面名会把漫画页标成书架。没有外壳页面名（独立挂载）
    // 时才回落组名。
    final String? pageName = FushiShellTitleScope.maybeTitleOf(context);
    final String soloTitle = pageName != null && pageName.isNotEmpty
        ? pageName
        : groups.isEmpty
        ? ''
        : groups.first.label;
    return LibraryChromeSpec<MediaLibraryViewKind>(
      title: pageName ?? '',
      groups: groups,
      selected: selected,
      currentGroup: currentGroup,
      // 停在导入页时「我的」组的高亮只是视觉锚点（BUG-4706）。
      selectedIsCurrent: currentGroup != null,
      onSelect: _select,
      focusIdPrefix: widget.focusIdPrefix,
      soloTitle: soloTitle,
      import: kinds.contains(MediaLibraryViewKind.sources)
          ? LibraryChromeImport(
              selected: selected == MediaLibraryViewKind.sources,
              onTap: _toggleImport,
              focusIdPrefix: widget.focusIdPrefix,
            )
          : null,
      actionsSlot: _actionsSlot,
      chrome: _chromeFor(selected),
      // 触屏横滑切到相邻视图，序即页签的视觉序：先「我的」组、再「在线」组，组内
      // 按声明序（与两级页签同一份真相），跨组照样接着滑，首 / 末再往外交给外层
      // 切模块。导入不是页签，只在停在导入页时排在最后（从它滑回相邻视图）。
      swipe: LibraryChromeSwipe<MediaLibraryViewKind>(
        sections: <MediaLibraryViewKind>[
          for (final LibrarySectionGroup group in LibrarySectionGroup.values)
            for (final MediaLibraryViewSpec spec in _membersOf(views, group))
              spec.kind,
          if (selected == MediaLibraryViewKind.sources)
            MediaLibraryViewKind.sources,
        ],
      ),
      navigationKey: _navigationKey,
      iconOf: _iconOf,
    );
  }

  /// 视图的侧栏图标（Apple macOS 档侧栏子项）。
  static IconData _iconOf(MediaLibraryViewKind kind) => switch (kind) {
    MediaLibraryViewKind.library => FushiIcons.books,
    MediaLibraryViewKind.mediaServers => FushiIcons.server,
    MediaLibraryViewKind.discover => FushiIcons.globe,
    MediaLibraryViewKind.browse => FushiIcons.globe,
    MediaLibraryViewKind.onlineSources => FushiIcons.cloud,
    MediaLibraryViewKind.extensions => FushiIcons.apps,
    MediaLibraryViewKind.sources => FushiIcons.libraryAdd,
  };

  /// [spec] 的视图内容（按种类缓存，见 [_viewCache]）。页签由壳的浮动工具栏
  /// 画出，视图页头的主位留空。
  Widget _viewFor(MediaLibraryViewSpec spec) => _viewCache[spec.kind] ??=
      _insetFor(spec, spec.builder(context, const SizedBox.shrink()));

  /// 把视图自己的滚动通知喂给它自己的 [chrome]（见 [_chromes]）。
  ///
  /// 隐藏的保活视图（后台加载把列表撑长 / 夹短）也照样更新自己那一份——那本来
  /// 就是它的状态，切回来时折叠进度与内容位置一致；它不在作用域里，影响不到
  /// 当前视图的工具栏。横滚卡片行的通知由 controller 按轴过滤。
  Widget _chromeFeed(FushiFloatingChromeController chrome, Widget child) =>
      NotificationListener<ScrollNotification>(
        onNotification: chrome.handleScrollNotification,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: chrome.handleScrollMetricsNotification,
          child: child,
        ),
      );

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
          // 「我的」组叫组名「媒体库」（与视频页同一口径）：页名（书架 / 漫画）
          // 已画在标题上，组页签再叫「书架」就紧挨着重复一遍。
          LibrarySectionGroup.library => t.library_view_media,
          LibrarySectionGroup.online => t.library_view_online,
        };
}
