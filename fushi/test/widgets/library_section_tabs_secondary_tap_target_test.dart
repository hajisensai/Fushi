import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';

// 库页二级下划线页签（`secondary: true`、非浮动）视觉降到 36 高后，命中区
// 不能跟着降到 M3 触控目标 48dp 以下：上下补透明命中带，点在带里命中正上 /
// 正下方那一段。

const List<String> _labels = <String>['书架', '媒体服务器', '发现'];

Future<ValueNotifier<int>> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(600, 300));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final ValueNotifier<int> selected = ValueNotifier<int>(0);
  addTearDown(selected.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            // 页签上下都留出空白：命中带落在空白里，不靠别的控件兜底。
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (BuildContext context, int value, Widget? _) =>
                  LibrarySectionTabs<int>(
                    tabs: <LibrarySectionTab<int>>[
                      for (int i = 0; i < _labels.length; i++)
                        LibrarySectionTab<int>(value: i, label: _labels[i]),
                    ],
                    selected: value,
                    onChanged: (int v) => selected.value = v,
                    focusIdPrefix: 'tap-target-test',
                    secondary: true,
                  ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return selected;
}

void main() {
  testWidgets('二级下划线页签视觉 36 高，整行命中区不低于 48', (WidgetTester tester) async {
    await _pump(tester);
    final Rect tab = tester.getRect(find.widgetWithText(Tab, '发现'));
    expect(tab.height, 36, reason: '视觉页签保持矮一档');
    final Rect row = tester.getRect(find.byType(LibrarySectionTabs<int>));
    expect(row.height, greaterThanOrEqualTo(kMinInteractiveDimension));
  });

  for (final bool above in <bool>[true, false]) {
    testWidgets('点在页签${above ? '上方' : '下方'}的透明命中带里命中该段', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<int> selected = await _pump(tester);
      final Rect tab = tester.getRect(find.widgetWithText(Tab, '发现'));
      final Rect row = tester.getRect(find.byType(LibrarySectionTabs<int>));
      // 离页签中线 22（48 命中区的一半是 24），落在 36 高的页签与它下面的
      // 指示条 / 分隔线之外，只有透明命中带能接住。
      final double y = tab.center.dy + (above ? -22 : 22);
      expect(y < tab.top - 1 || y > tab.bottom + 1, isTrue);
      expect(y, inInclusiveRange(row.top, row.bottom));
      await tester.tapAt(Offset(tab.center.dx, y));
      await tester.pumpAndSettle();
      expect(selected.value, 2);
    });
  }

  testWidgets('命中区外（48 带以外）不响应', (WidgetTester tester) async {
    final ValueNotifier<int> selected = await _pump(tester);
    final Rect tab = tester.getRect(find.widgetWithText(Tab, '发现'));
    final Rect row = tester.getRect(find.byType(LibrarySectionTabs<int>));
    await tester.tapAt(Offset(tab.center.dx, row.bottom + 4));
    await tester.pumpAndSettle();
    expect(selected.value, 0);
  });
}
