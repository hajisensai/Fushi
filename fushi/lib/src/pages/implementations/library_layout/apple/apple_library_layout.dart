import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_import_button.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_scope_bar.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_title_menu.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_zoom_button.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_sidebar_library_section.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_grid_zoom.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup;
import 'package:fushi/src/pages/shared/library_section_tabs.dart'
    show resolveSectionTabOrderStore;
import 'package:fushi/src/utils/adaptive/apple_sidebar_library_host.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellTitleScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show fushiAppleUsesMacMetrics;
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/section_tab_order.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// Apple（Cupertino，iOS 27 / macOS 27）库页外壳：2026-11-24 用户拍板的方案 A
/// （Apple Books 式）+ 方案 C 的「缩放调每行个数」。
///
/// - 顶部：iOS 大标题导航栏 / macOS 常驻工具栏（与其它模块页同一套
///   [FushiFloatingChromeBar] Apple 几何：滚动后大标题缩进导航栏）。右上是视图
///   登记的动作组（宽度够就平铺、放不下才收「⋯」）+「导入」中性玻璃圆钮。
/// - 一级分组（媒体库 / 在线）：大标题本身是下拉菜单（[AppleLibraryTitleMenu]），
///   菜单末尾「调整页签顺序…」。
/// - 二级分区：iOS 档（窄屏）与侧栏收成标签栏时在标题下画分区胶囊行
///   （[AppleLibraryScopeBar]）；macOS 档宽窗由侧栏把当前模块展开成「分区 + 在线」
///   子项（[AppleSidebarLibrarySection] 登记进 [AppleSidebarLibraryHost]），内容区
///   不再重复画胶囊行，标题换成当前分区名。
/// - 网格每行个数：视图经 [LibraryGridZoom] 接双指捏合 / ⌘+ ⌘−，macOS 档在
///   工具栏右端多一枚「每行数量」钮（[AppleLibraryZoomButton]，点开弹出缩放滑杆）。
///
/// 只在 `isGlassDesign` 为真时由 [LibraryLayout] 选用；M3E 不经过这里。
class AppleLibraryLayout<T extends Object> extends StatefulWidget {
  const AppleLibraryLayout({required this.spec, required this.body, super.key});

  final LibraryChromeSpec<T> spec;
  final Widget body;

  @override
  State<AppleLibraryLayout<T>> createState() => _AppleLibraryLayoutState<T>();
}

class _AppleLibraryLayoutState<T extends Object>
    extends State<AppleLibraryLayout<T>> {
  /// 落库前的乐观组内顺序（排序面板里每调一次先重排，不等偏好写完），按
  /// orderKey 存。
  final Map<String, List<String>> _pendingOrder = <String, List<String>>{};

  /// 当前视图登记的网格缩放口（macOS 档工具栏滑杆读它）。
  final LibraryGridZoomHub _zoomHub = LibraryGridZoomHub();

  /// 最近一次登记到的侧栏宿主（卸下时撤回用）。
  AppleSidebarLibraryHost? _host;

  @override
  void dispose() {
    _zoomHub.dispose();
    super.dispose();
  }

  /// [group] 内按用户顺序排好的分区。
  List<LibrarySectionTab<T>> _ordered(LibraryChromeGroup<T> group) {
    final String? key = group.orderKey;
    if (key == null) return group.members;
    final SectionTabOrderStore? store = resolveSectionTabOrderStore(context);
    final List<String> ids =
        _pendingOrder[key] ?? store?.read(key) ?? const <String>[];
    return orderSectionTabs(group.members, ids);
  }

  /// 打开 [group] 的组内排序面板（与 M3E 长按页签同一个面板、同一份存储）。
  VoidCallback? _reorderAction(LibraryChromeGroup<T>? group) {
    final String? key = group?.orderKey;
    if (group == null || key == null || group.members.length < 2) return null;
    final SectionTabOrderStore? store = resolveSectionTabOrderStore(context);
    if (store == null) return null;
    return () => unawaited(
      showSectionTabOrderSheet<T>(
        context: context,
        tabs: _ordered(group),
        defaultOrder: group.members,
        onChanged: (List<LibrarySectionTab<T>> next) {
          final List<String> ids = <String>[
            for (final LibrarySectionTab<T> tab in next) sectionTabOrderId(tab),
          ];
          setState(() => _pendingOrder[key] = ids);
          unawaited(_persist(store, key, ids));
        },
        onReset: () {
          setState(() => _pendingOrder[key] = const <String>[]);
          unawaited(_persist(store, key, const <String>[]));
        },
      ),
    );
  }

  Future<void> _persist(
    SectionTabOrderStore store,
    String key,
    List<String> ids,
  ) async {
    try {
      await store.write(key, ids);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'apple_library_layout',
          context: ErrorDescription('while saving the section tab order'),
        ),
      );
    } finally {
      // 落库后以存储真值为准；失败时也撤掉乐观顺序。
      if (mounted) setState(() => _pendingOrder.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final LibraryChromeSpec<T> spec = widget.spec;
    final AppleSidebarLibraryHost? host = AppleSidebarLibraryScope.maybeOf(
      context,
    );
    final bool macMetrics = fushiAppleUsesMacMetrics(context);
    final bool sidebarHosts = appleSidebarHostsLibrarySections(
      host: host,
      macMetrics: macMetrics,
      groupCount: spec.groups.length,
    );
    final LibraryChromeGroup<T>? shownGroup = spec.shownGroup;
    final List<LibrarySectionTab<T>> shownSections = shownGroup == null
        ? const <Never>[]
        : _ordered(shownGroup);
    final LibraryChromeImport? import = spec.import;
    // 停在导入页（Cupertino 导入页方案 A）：大标题是「导入」，不画标题菜单与分区
    // 胶囊行（副标题「到 〈库名〉」由导入页自己画，回库点「导入」钮 / 侧栏分区）。
    final bool onImport = import?.selected ?? false;

    // 标题菜单（一级分组 + 调整顺序）：侧栏承载分区时不需要。
    final VoidCallback? reorder = _reorderAction(spec.current);
    final bool titleMenu =
        !onImport &&
        !sidebarHosts &&
        (spec.groups.length >= 2 || reorder != null);
    Widget wrapTitle(BuildContext context, Widget title, TextStyle style) =>
        AppleLibraryTitleMenu(
          title: title,
          titleStyle: style,
          focusIdPrefix: spec.focusIdPrefix,
          onReorder: reorder,
          entries: <AppleLibraryTitleMenuEntry>[
            for (final LibraryChromeGroup<T> group in spec.groups)
              AppleLibraryTitleMenuEntry(
                label: group.label,
                icon: switch (group.group) {
                  LibrarySectionGroup.library => FushiIcons.books,
                  LibrarySectionGroup.online => FushiIcons.globe,
                },
                selected: group.group == spec.currentGroup,
                onSelect: () => spec.onSelect(group.value),
              ),
          ],
        );

    final Widget? scopeBar =
        onImport || sidebarHosts || shownSections.length < 2
        ? null
        : AppleLibraryScopeBar<T>(
            // 换组即换一排胶囊（段数与段值都变）。
            key: ValueKey<LibrarySectionGroup?>(shownGroup?.group),
            sections: shownSections,
            selected: spec.currentGroup == null ? null : spec.selected,
            selectedIsCurrent: spec.selectedIsCurrent,
            onSelect: spec.onSelect,
            focusIdPrefix: shownGroup?.subFocusIdPrefix ?? spec.focusIdPrefix,
          );

    Widget chrome = FushiFloatingChromeBar(
      // 一级分组不再是分段控件：由标题菜单 / 侧栏承载。
      tabs: const SizedBox.shrink(),
      slot: spec.actionsSlot,
      titleWrapper: titleMenu ? wrapTitle : null,
      trailing: _trailing(import, macMetrics: macMetrics),
      secondary: _secondary(scopeBar, spec.accessory),
    );
    // 大标题恒在（它本身就是一级分组的菜单入口）：侧栏已标出模块与分区时内容区
    // 标题换成当前分区名（macOS Finder / Music 的做法；停在导入页时是「导入」）；
    // 没有外壳页名（独立挂载）时回落当前组名。
    final String sectionTitle = onImport
        ? t.library_view_import
        : (sidebarHosts ? _currentSectionLabel(spec) : null) ?? spec.title;
    chrome = FushiShellTitleScope(
      title: sectionTitle.isNotEmpty
          ? sectionTitle
          : spec.shownGroup?.label ?? '',
      actionsSlot: spec.actionsSlot,
      child: chrome,
    );

    // 侧栏登记：所在 tab 可见时登记、隐藏即撤回（见 [AppleSidebarLibraryHost]）。
    if (_host != host) _host?.publish(this, null);
    _host = host;
    final AppleSidebarLibraryHost? publishTo = host;
    if (publishTo != null) {
      publishTo.publish(
        this,
        SectionVisibility.of(context)
            ? appleSidebarLibraryRows<T>(spec: spec, ordered: _ordered)
            : null,
      );
    }

    Widget body = widget.body;
    final LibraryChromeSwipe<T>? swipe = spec.swipe;
    if (swipe != null) {
      body = SectionSwipeNavigator<T>(
        sections: swipe.sections,
        selected: spec.selected,
        onSelect: spec.onSelect,
        child: body,
      );
    }
    return LibraryGridZoomHubScope(
      hub: _zoomHub,
      child: FushiFloatingChromeScope(
        controller: spec.chrome,
        child: FushiFloatingChromeOverlay(
          masthead: true,
          chrome: chrome,
          child: body,
        ),
      ),
    );
  }

  /// 标题下的分区区：分区胶囊行 + 视图自己的三级行（如音乐推荐页的来源页签）。
  Widget? _secondary(Widget? scopeBar, Widget? accessory) {
    if (accessory == null || scopeBar == null) return scopeBar ?? accessory;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: <Widget>[scopeBar, accessory],
    );
  }

  /// 工具栏右端：macOS 档的「每行数量」钮（当前视图登记了网格缩放时，点开弹出
  /// 缩放滑杆）+「导入」。
  Widget? _trailing(LibraryChromeImport? import, {required bool macMetrics}) {
    final Widget? importButton = import == null
        ? null
        : AppleLibraryImportButton(
            key: ValueKey<String>('${import.focusIdPrefix}-import'),
            selected: import.selected,
            onTap: import.onTap,
          );
    if (!macMetrics) return importButton;
    return ListenableBuilder(
      listenable: _zoomHub,
      builder: (BuildContext context, Widget? _) {
        final LibraryGridZoomPort? port = _zoomHub.port;
        if (port == null) return importButton ?? const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppleLibraryZoomButton(port: port),
            if (importButton != null) ...<Widget>[
              const SizedBox(width: 8),
              importButton,
            ],
          ],
        );
      },
    );
  }

  @override
  void deactivate() {
    // 卸下（换 tab 父节点 / 整页销毁）时撤回侧栏登记；重新挂上会重建、再登记。
    _host?.publish(this, null);
    super.deactivate();
  }

  /// 当前分区的显示名；停在导入页时为 null。
  String? _currentSectionLabel(LibraryChromeSpec<T> spec) {
    final LibraryChromeGroup<T>? group = spec.current;
    if (group == null) return null;
    for (final LibrarySectionTab<T> tab in group.members) {
      if (tab.value == spec.selected) {
        return group.members.length == 1 &&
                group.group == LibrarySectionGroup.library
            ? spec.title
            : tab.label;
      }
    }
    return null;
  }
}

/// 侧栏是否承载库页分区（内容区不画胶囊行、不画标题菜单）：Apple 宽窗侧栏外壳
/// 在侧栏形态（不是收成顶部标签栏）、macOS 档度量、且库页确实有分区可展开。
bool appleSidebarHostsLibrarySections({
  required AppleSidebarLibraryHost? host,
  required bool macMetrics,
  required int groupCount,
}) => host != null && host.sidebarMode && macMetrics && groupCount > 0;
