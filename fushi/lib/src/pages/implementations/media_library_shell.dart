import 'package:flutter/material.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/utils.dart';

/// 库页视图种类：一个顶层 tab 内部的几个平级视图。
///
/// 三个媒体域（书 / 漫画 / 视频）共用同一套导航结构，但**各域只声明自己真正有的
/// 视图**——视频没有在线浏览源就不显示 [browse]，绝不放空壳 tab。
enum MediaLibraryViewKind {
  /// 已入库条目（书架 / 媒体库）。
  library,

  /// 在线源浏览（漫画的 mokuro.moe 目录；将来小说源同位）。
  browse,

  /// 来源管理：本地扫描根 + 在线源设置 + 漫画扩展（扩展本身就是「来源」，
  /// 不单开 tab）。
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
  });

  final MediaLibraryViewKind kind;
  final String label;
  final Widget Function(BuildContext context, Widget navigation) builder;
}

/// 向壳内子树暴露「切到某个视图」的能力（[InheritedWidget]，不改 builder 签名）。
///
/// 动因：库页空态的引导按钮要能把用户带到「导入」视图（[MediaLibraryViewKind.sources]），
/// 而空态 widget 埋在书架页深处——层层回调穿透会让三个库页壳的构造签名全部膨胀。
/// 子树用 [maybeOf] 取到后调 [select]；不在壳内（书架被独立 push）时拿到 null，
/// 调用方自行回退（如直接开导入对话框）。
class MediaLibraryShellScope extends InheritedWidget {
  const MediaLibraryShellScope({
    required this.select,
    required super.child,
    super.key,
  });

  /// 切到指定视图；壳没有该视图时静默忽略。
  final void Function(MediaLibraryViewKind kind) select;

  static MediaLibraryShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaLibraryShellScope>();

  @override
  bool updateShouldNotify(MediaLibraryShellScope oldWidget) =>
      select != oldWidget.select;
}

/// 库页视图导航壳：在一个顶层 tab 内切换 [MediaLibraryViewSpec] 声明的若干视图。
///
/// 设计要点：
/// - **只有一个视图时不显示导航条**（`navigation` 传空占位）。这样「某域暂时没有
///   在线源」不需要在调用侧写条件分支，也不会出现点了没内容的死 tab。
/// - 视图**惰性构建 + 保活**（Offstage + TickerMode），与顶层 tab 的做法同源
///   （`home_page.dart` 的 `_visitedKeepAliveTabs`）：没访问过的视图不构建（在线目录
///   不会因为壳挂载就发网络请求），访问过的切走仍保留滚动位置/搜索词，切回不重建。
/// - 导航条只交给**当前**视图。分段条内部要注册一个方向焦点停靠点，同一个
///   focusIdPrefix 注册两次会互相打架，所以隐藏的视图拿到的是空占位（它们本就不可见）。
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

  void _select(MediaLibraryViewKind kind) {
    final int index = widget.views
        .indexWhere((MediaLibraryViewSpec spec) => spec.kind == kind);
    if (index < 0 || index == _currentIndex) return;
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
    if (views.length < 2) {
      return MediaLibraryShellScope(
        select: _select,
        child: views.first.builder(context, const SizedBox.shrink()),
      );
    }
    final Widget navigation = _buildNavigation(views);
    return MediaLibraryShellScope(
      select: _select,
      child: Stack(
        children: <Widget>[
          for (int i = 0; i < views.length; i++)
            if (_visited.contains(i))
              Offstage(
                offstage: i != _currentIndex,
                child: TickerMode(
                  enabled: i == _currentIndex,
                  child: views[i].builder(
                    context,
                    i == _currentIndex ? navigation : const SizedBox.shrink(),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildNavigation(List<MediaLibraryViewSpec> views) {
    final MediaLibraryViewKind selected = views[_currentIndex].kind;
    final List<MediaLibraryViewKind> values = views
        .map((MediaLibraryViewSpec spec) => spec.kind)
        .toList(growable: false);
    // 分段条必须包 [FushiAdjustableSegmented]：否则它只是一堆原生按钮，只遍历已注册
    // target 的方向焦点控制器会整个跳过（手柄/键盘用户切不了视图）。包上后是单个焦点
    // 停靠点，左右方向键原地切视图。
    return FushiAdjustableSegmented<MediaLibraryViewKind>(
      values: values,
      selected: selected,
      onChanged: _select,
      focusIdPrefix: widget.focusIdPrefix,
      focusId: FushiFocusId('${widget.focusIdPrefix}-sections'),
      child: FushiSegmentedStrip<MediaLibraryViewKind>(
        segments: <ButtonSegment<MediaLibraryViewKind>>[
          for (final MediaLibraryViewSpec spec in views)
            ButtonSegment<MediaLibraryViewKind>(
              value: spec.kind,
              label: Text(spec.label),
            ),
        ],
        selected: selected,
        onChanged: _select,
      ),
    );
  }
}
