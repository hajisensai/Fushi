import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup, libraryImportChromeButton;
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';

/// M3E 库页外壳（[LibraryChromeSpec] 的 Material 画法）：与 2026-10-30 定版
/// 完全相同的结构——外壳大字行（页名 + 一级「媒体库 | 在线」按钮组 + 右侧悬浮
/// 动作组 + 「导入」主按钮），其下二级 M3 secondary tabs，整摞浮动工具区叠在
/// 内容上、随滚动收放（[FushiFloatingChromeOverlay]）。
///
/// 这里是书架 / 漫画（`MediaLibraryShell`）与视频（`VideoLibraryShell`）原先
/// 各自内联的那段外壳原样搬过来，行为与像素不变；壳只产出 spec 与内容。
class MaterialLibraryLayout<T extends Object> extends StatelessWidget {
  const MaterialLibraryLayout({
    required this.spec,
    required this.body,
    super.key,
  });

  final LibraryChromeSpec<T> spec;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final Widget? subTabs = _buildSubTabs();
    final Widget subNavigation = subTabs == null
        ? const SizedBox.shrink()
        : Padding(
            // 与顶栏胶囊、页面内容同一条页边；两级页签之间的 12 由嵌套层统一给
            // （[kFushiFloatingChromeGap] + 顶栏底边 4），这里不再叠竖向留白。
            padding: EdgeInsets.symmetric(
              horizontal: FushiDesignTokens.of(context).spacing.page,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: subTabs,
            ),
          );
    Widget swiped(Widget child) {
      final LibraryChromeSwipe<T>? swipe = spec.swipe;
      if (swipe == null) return child;
      // 触屏横滑切到相邻视图，序即页签的视觉序（宿主给）。
      return SectionSwipeNavigator<T>(
        sections: swipe.sections,
        selected: spec.selected,
        onSelect: spec.onSelect,
        child: child,
      );
    }

    // 二级胶囊行叠在页面上、与顶栏同一份显隐（嵌套的
    // [FushiFloatingChromeOverlay] 读同一个作用域，视图的顶部让位自动累加
    // 两行）；当前组只有一个视图（或在导入页）时不占高度。
    Widget nested(Widget child) => FushiFloatingChromeOverlay(
      // 二级下划线页签贴着顶栏，不再隔 8（见 nestedGap）。
      nestedGap: 0,
      opaqueChrome: true,
      masthead: true,
      chrome: subNavigation,
      child: child,
    );

    final LibraryChromeImport? import = spec.import;
    return FushiFloatingChromeScope(
      // 当前视图自己的工具栏状态。
      controller: spec.chrome,
      // 工具栏叠在内容上，收起只滑出画面、不改内容视口高度（滚轮上下「回弹、
      // 滚不动」的根因是收起改了视口高度，BUG-2975，见
      // [FushiFloatingChromeOverlay]）。
      child: FushiFloatingChromeOverlay(
        // 重设计外壳下画成页头大字（`fushi_page_masthead.dart`）。
        masthead: true,
        chrome: FushiFloatingChromeBar(
          tabs: _buildNavigation(),
          slot: spec.actionsSlot,
          trailing: import == null
              ? null
              : libraryImportChromeButton(
                  selected: import.selected,
                  onTap: import.onTap,
                  focusIdPrefix: import.focusIdPrefix,
                  anchorKey: import.anchorKey,
                ),
          // 页头大字顶栏里二级页签由大字行画（放得下与页名同一行）。
          secondary: subTabs,
        ),
        child: spec.swipeCoversSubNavigation
            ? swiped(nested(body))
            : nested(swiped(body)),
      ),
    );
  }

  /// 一级分组页签；只剩一组时换成标题（或空）。
  Widget _buildNavigation() {
    final List<LibrarySectionTab<T>> tabs = spec.groupTabs;
    // 一级只剩一组（iOS 合规门下没有在线视图）时不画胶囊，页签位置改放标题。
    if (tabs.length < 2) {
      final String? solo = spec.soloTitle;
      return solo == null
          ? const SizedBox.shrink()
          : FushiFloatingChromeSoloTitle(title: solo);
    }
    // 停在导入页时高亮「我的」组：导入管理的就是本地库。此时高亮只是视觉锚点、
    // 不是当前视图（[LibrarySectionTabs.selectedIsCurrent]），点它照常切回
    // （BUG-4706）。
    final LibraryChromeGroup<T>? current = spec.current;
    return LibrarySectionTabs<T>(
      key: spec.navigationKey,
      tabs: tabs,
      selected: current?.value ?? tabs.first.value,
      selectedIsCurrent: spec.selectedIsCurrent,
      onChanged: spec.onSelect,
      focusIdPrefix: spec.focusIdPrefix,
      floating: true,
    );
  }

  /// 当前组的二级页签本体（不带页边 / 对齐）；组内只有一个视图或停在导入页时
  /// 为 null。页头大字顶栏里交给大字行（[FushiFloatingChromeBar.secondary]）。
  Widget? _buildSubTabs() {
    final LibraryChromeGroup<T>? group = spec.current;
    final List<LibrarySectionTab<T>> members = spec.subSections;
    if (group == null || members.isEmpty) return null;
    return LibrarySectionTabs<T>(
      // 换组即换一份页签（段数与段值都变），不复用旧 controller。
      key: ValueKey<LibrarySectionGroup>(group.group),
      tabs: members,
      selected: spec.selected,
      selectedIsCurrent: spec.selectedIsCurrent,
      onChanged: spec.onSelect,
      focusIdPrefix: group.subFocusIdPrefix,
      // 二级用 M3 secondary tabs（文字 + 横贯下划线），不再是第二枚浮动胶囊：
      // 与一级按钮组胶囊拉开层级（2026-10-30 用户拍板方案 B）。
      secondary: true,
      // 反馈 ndQ5eXLcqp：长按 / 右键页签栏自定义组内顺序。
      orderKey: group.orderKey,
    );
  }
}
