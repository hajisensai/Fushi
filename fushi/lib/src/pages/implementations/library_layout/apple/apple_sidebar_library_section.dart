import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup;
import 'package:fushi/src/utils/adaptive/apple_sidebar_library_host.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/section_tab_order.dart'
    show sectionTabOrderId;
import 'package:fushi/src/utils/fushi_icons.dart';

/// macOS 档侧栏里当前库页展开的子项（方案 A）：
///
/// - 「我的」组（媒体库）的每个分区各一行（书架 / 媒体服务器；视频是首页 /
///   系列 / 全部视频 / 媒体服务器）；
/// - 「在线」组：只有一个分区时直接是那一行；多个分区时是一行「在线」，当前就在
///   在线组里时它下面再缩进一级列出发现 / 在线来源 / 扩展。
///
/// 有导入页的库（[LibraryChromeSpec.import]）在分区末尾多一行「导入」（Cupertino
/// 导入页拍板第 2 条），与工具栏「导入」钮联动：停在导入页时只有它高亮，点它
/// 不会切回（已在导入页时是空操作）。纯数据，渲染在 `AppleSidebarTabsShell`。
List<AppleSidebarLibraryRow> appleSidebarLibraryRows<T extends Object>({
  required LibraryChromeSpec<T> spec,
  required List<LibrarySectionTab<T>> Function(LibraryChromeGroup<T> group)
  ordered,
}) {
  final List<AppleSidebarLibraryRow> rows = <AppleSidebarLibraryRow>[];
  final bool onTab = spec.currentGroup != null;
  IconData? iconOf(T value) => spec.iconOf?.call(value);
  AppleSidebarLibraryRow sectionRow(
    LibraryChromeGroup<T> group,
    LibrarySectionTab<T> tab, {
    required int depth,
  }) => AppleSidebarLibraryRow(
    id: '${spec.focusIdPrefix}-${group.group.name}-${sectionTabOrderId(tab)}',
    label: tab.label,
    icon: iconOf(tab.value),
    depth: depth,
    selected: onTab && tab.value == spec.selected,
    onTap: () => spec.onSelect(tab.value),
  );

  for (final LibraryChromeGroup<T> group in spec.groups) {
    final List<LibrarySectionTab<T>> members = ordered(group);
    if (members.isEmpty) continue;
    final bool library = group.group == LibrarySectionGroup.library;
    if (library || members.length == 1) {
      for (final LibrarySectionTab<T> tab in members) {
        rows.add(sectionRow(group, tab, depth: 1));
      }
      continue;
    }
    final bool inGroup = spec.currentGroup == group.group;
    rows.add(
      AppleSidebarLibraryRow(
        id: '${spec.focusIdPrefix}-${group.group.name}',
        label: group.label,
        icon: FushiIcons.globe,
        // 组行只在组折叠（不在组内）时可能高亮：在组内时由下面的分区行高亮。
        selected: false,
        onTap: () => spec.onSelect(group.value),
      ),
    );
    if (inGroup) {
      for (final LibrarySectionTab<T> tab in members) {
        rows.add(sectionRow(group, tab, depth: 2));
      }
    }
  }
  final LibraryChromeImport? import = spec.import;
  if (import != null) {
    rows.add(
      AppleSidebarLibraryRow(
        id: '${spec.focusIdPrefix}-sidebar-import',
        label: t.library_view_import,
        icon: FushiIcons.libraryAdd,
        selected: import.selected,
        onTap: import.selected ? _keepImport : import.onTap,
      ),
    );
  }
  return rows;
}

void _keepImport() {}
