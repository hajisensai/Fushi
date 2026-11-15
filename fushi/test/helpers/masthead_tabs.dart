// 库页「页头大字」顶栏（`fushi_page_masthead.dart`，PR #3397 重设计外壳）里的
// 页签读取 / 驱动工具：一级切换是 [FushiMastheadSwitch]（大字「书架 / 在线」），
// 二级页签是 [FushiMastheadSegmentedTabs]（连体按钮组）。两者都只有
// `tabs / selected / onChanged`，测试统一按 [MastheadTabsView] 读。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadSegmentedTabs, FushiMastheadSwitch;
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:material_ui/material_ui.dart';

/// 一排页头大字页签的只读视图。
class MastheadTabsView<T extends Object> {
  const MastheadTabsView({
    required this.tabs,
    required this.selected,
    required this.onChanged,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  List<T> get values => <T>[
    for (final LibrarySectionTab<T> tab in tabs) tab.value,
  ];

  List<String> get labels => <String>[
    for (final LibrarySectionTab<T> tab in tabs) tab.label,
  ];
}

/// 一级切换（大字行里的「组」页签）。
Finder mastheadPrimaryTabs<T extends Object>() =>
    find.byType(FushiMastheadSwitch<T>);

/// 二级页签（连体按钮组）。
Finder mastheadSecondaryTabs<T extends Object>() =>
    find.byType(FushiMastheadSegmentedTabs<T>);

/// 读 [finder] 命中的唯一一排页签。
MastheadTabsView<T> readMastheadTabs<T extends Object>(
  WidgetTester tester,
  Finder finder,
) {
  final Widget widget = tester.widget(finder);
  if (widget is FushiMastheadSwitch<T>) {
    return MastheadTabsView<T>(
      tabs: widget.tabs,
      selected: widget.selected,
      onChanged: widget.onChanged,
    );
  }
  if (widget is FushiMastheadSegmentedTabs<T>) {
    return MastheadTabsView<T>(
      tabs: widget.tabs,
      selected: widget.selected,
      onChanged: widget.onChanged,
    );
  }
  throw StateError('不是页头大字页签：${widget.runtimeType}');
}
