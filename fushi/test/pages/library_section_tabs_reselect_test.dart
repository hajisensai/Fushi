import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadRole, FushiMastheadScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';

/// BUG-4706：[LibrarySectionTabs.selectedIsCurrent] 在每种画法下都必须成立。
///
/// 库页壳停在导入页（不属于任何页签）时高亮「我的」组只是视觉锚点：点它必须
/// 照常回调；高亮项就是当前视图时（默认）点它仍按重复点击吞掉。四种画法——页头
/// 大字一级 / 二级、Apple 非页头大字分段控件、MD3 TabBar——逐一真实点击验证，
/// 不只看参数有没有接上。
void main() {
  const List<LibrarySectionTab<String>> tabs = <LibrarySectionTab<String>>[
    LibrarySectionTab<String>(value: 'shelf', label: 'Shelf'),
    LibrarySectionTab<String>(value: 'online', label: 'Online'),
  ];

  ThemeData theme({required bool glass}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: glass,
  );

  Future<List<String>> tapHighlighted(
    WidgetTester tester, {
    required bool selectedIsCurrent,
    required bool glass,
    FushiMastheadRole? role,
  }) async {
    final List<String> calls = <String>[];
    final Widget strip = LibrarySectionTabs<String>(
      tabs: tabs,
      selected: 'shelf',
      selectedIsCurrent: selectedIsCurrent,
      onChanged: calls.add,
      focusIdPrefix: 'reselect-test',
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass),
        home: FushiGlassScope(
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: role == null
                  ? strip
                  : FushiMastheadScope(role: role, child: strip),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shelf').first);
    await tester.pumpAndSettle();
    return calls;
  }

  final Map<String, ({bool glass, FushiMastheadRole? role})> forms =
      <String, ({bool glass, FushiMastheadRole? role})>{
        '页头大字一级': (glass: false, role: FushiMastheadRole.primary),
        '页头大字二级': (glass: false, role: FushiMastheadRole.secondary),
        'Apple 页头大字一级': (glass: true, role: FushiMastheadRole.primary),
        'Apple 非页头大字分段控件': (glass: true, role: null),
        'MD3 TabBar': (glass: false, role: null),
      };

  for (final MapEntry<String, ({bool glass, FushiMastheadRole? role})> form
      in forms.entries) {
    testWidgets('${form.key}：高亮只是锚点时点它照常回调', (WidgetTester tester) async {
      final List<String> calls = await tapHighlighted(
        tester,
        selectedIsCurrent: false,
        glass: form.value.glass,
        role: form.value.role,
      );
      expect(calls, <String>['shelf']);
    });
  }

  // 默认（高亮即当前视图）点当前项不回调——MD3 TabBar 本就逐次回调、由宿主
  // 去重，不在此列。
  for (final MapEntry<String, ({bool glass, FushiMastheadRole? role})> form
      in forms.entries.where(
        (MapEntry<String, ({bool glass, FushiMastheadRole? role})> e) =>
            e.key != 'MD3 TabBar',
      )) {
    testWidgets('${form.key}：默认点当前项仍按重复点击吞掉', (WidgetTester tester) async {
      final List<String> calls = await tapHighlighted(
        tester,
        selectedIsCurrent: true,
        glass: form.value.glass,
        role: form.value.role,
      );
      expect(calls, isEmpty);
    });
  }
}
