import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeController;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot;
import 'package:fushi/src/utils/components/library_section_tab.dart';

/// 库页外壳要画什么（纯数据，2026-11-24 用户拍板「Cupertino 库页独立布局」）。
///
/// 四类库页壳（`MediaLibraryShell` 书架 / 漫画、`VideoLibraryShell`、游戏、音乐）
/// 只产出这一份 spec 与内容（[LibraryLayout] 的 `body`），不再自己判断设计系统；
/// [LibraryLayout] 按 `isGlassDesign` 分派到 `MaterialLibraryLayout`（M3E 原样：
/// 浮动工具栏 + 两级胶囊页签）或 `AppleLibraryLayout`（方案 A：大标题菜单 +
/// 分区胶囊行 / macOS 侧栏展开）。
///
/// 一级分组（[groups]）恒为一到两个（「媒体库 / 在线」，见 [LibrarySectionGroup]），
/// 组内是若干分区（[LibraryChromeGroup.members]）；导入页不属于任何组
/// （[currentGroup] 为 null）。
@immutable
class LibraryChromeSpec<T extends Object> {
  const LibraryChromeSpec({
    required this.title,
    required this.groups,
    required this.selected,
    required this.currentGroup,
    required this.onSelect,
    required this.focusIdPrefix,
    required this.actionsSlot,
    required this.chrome,
    this.selectedIsCurrent = true,
    this.soloTitle,
    this.import,
    this.swipe,
    this.swipeCoversSubNavigation = false,
    this.navigationKey,
    this.iconOf,
  });

  /// 页面名（外壳给本 tab 的名字：书架 / 漫画 / 视频 / 游戏）。
  final String title;

  /// 一级分组（按显示序）；为空 = 只有一个视图、不画任何分区导航。
  final List<LibraryChromeGroup<T>> groups;

  /// 当前高亮的分区值（停在导入页时是「我的」组的代表值，见
  /// [selectedIsCurrent]）。
  final T selected;

  /// 当前所在的一级分组；停在导入页（或游戏的诊断页）时为 null。
  final LibrarySectionGroup? currentGroup;

  /// false = [selected] 只是视觉锚点（停在导入页时高亮「我的」组），点中它也
  /// 必须照常回调 [onSelect]（BUG-4706）。
  final bool selectedIsCurrent;

  /// 切到某个分区（壳自己的 `_select`）。
  final ValueChanged<T> onSelect;

  /// 一级页签的焦点 id 前缀（每个库页一个，避免多库同时挂载时撞 id）。
  final String focusIdPrefix;

  /// 一级只剩一组时页签位改放的标题（M3E `FushiFloatingChromeSoloTitle`）；
  /// null = 不画（游戏库）。
  final String? soloTitle;

  /// 工具栏右端的「导入」入口；null = 本库没有导入页。
  final LibraryChromeImport? import;

  /// 视图页头登记动作的槽（右上动作组画出）。
  final FushiShellActionsSlot actionsSlot;

  /// 当前视图自己的工具栏状态（显隐 / 折叠进度）。
  final FushiFloatingChromeController chrome;

  /// 触屏横滑切相邻分区；null = 不支持。
  final LibraryChromeSwipe<T>? swipe;

  /// M3E：横滑区域是否包住二级页签行（视频库包住，书架 / 漫画只包内容）。
  /// 只为保持 M3E 行为逐像素不变；Apple 外壳忽略。
  final bool swipeCoversSubNavigation;

  /// M3E 一级页签的身份（书架 / 漫画：切视图时指示条在同一个 State 上滑过去）。
  final GlobalKey? navigationKey;

  /// 分区的图标（Apple macOS 档侧栏子项用）；null = 不画图标。
  final IconData Function(T value)? iconOf;

  /// 当前组（停在导入页时为 null）。
  LibraryChromeGroup<T>? get current {
    final LibrarySectionGroup? group = currentGroup;
    if (group == null) return null;
    for (final LibraryChromeGroup<T> g in groups) {
      if (g.group == group) return g;
    }
    return null;
  }

  /// 分区行要展示的组：当前组；停在导入页时是第一组（「我的」，导入管理的就是
  /// 本地库）。没有任何组时为 null。
  LibraryChromeGroup<T>? get shownGroup =>
      current ?? (groups.isEmpty ? null : groups.first);

  /// 当前组的二级分区（不足两段时为空：不画二级导航）。
  List<LibrarySectionTab<T>> get subSections {
    final LibraryChromeGroup<T>? group = current;
    if (group == null || group.members.length < 2) {
      return <LibrarySectionTab<T>>[];
    }
    return group.members;
  }

  /// 一级分组页签（值 = 组的代表分区，顺序身份认组）。
  List<LibrarySectionTab<T>> get groupTabs => <LibrarySectionTab<T>>[
    for (final LibraryChromeGroup<T> g in groups)
      LibrarySectionTab<T>(
        value: g.value,
        label: g.label,
        orderId: g.group.name,
      ),
  ];
}

/// 一个一级分组：组名 + 组内分区 + 点组时去的分区。
@immutable
class LibraryChromeGroup<T extends Object> {
  const LibraryChromeGroup({
    required this.group,
    required this.label,
    required this.value,
    required this.members,
    required this.subFocusIdPrefix,
    this.orderKey,
  });

  final LibrarySectionGroup group;

  /// 组页签文案（「媒体库」/「在线」；组内只有一个分区时是那个分区名）。
  final String label;

  /// 点组页签时去的分区：当前就在组内时是当前分区，否则是组内上次停留的。
  final T value;

  /// 组内分区（按显示序，未应用用户自定义顺序）。
  final List<LibrarySectionTab<T>> members;

  /// 二级页签的焦点 id 前缀。
  final String subFocusIdPrefix;

  /// 用户自定义组内顺序的存储键（`section_tab_order::<orderKey>`）；null = 不可调。
  final String? orderKey;
}

/// 工具栏右端「导入」入口（切换型：停在导入页时呈选中态，再点一次回去）。
@immutable
class LibraryChromeImport {
  const LibraryChromeImport({
    required this.selected,
    required this.onTap,
    required this.focusIdPrefix,
    this.anchorKey,
  });

  final bool selected;
  final VoidCallback onTap;
  final String focusIdPrefix;

  /// 导入是一组零散动作（音乐）时弹菜单的锚点。
  final GlobalKey? anchorKey;
}

/// 横滑切分区的序（与页签视觉序同一份真相）。
@immutable
class LibraryChromeSwipe<T extends Object> {
  const LibraryChromeSwipe({required this.sections});

  /// 按视觉序排列的分区值；当前分区不在其中时不响应。
  final List<T> sections;
}
