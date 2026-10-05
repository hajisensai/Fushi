import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/browse_page.dart';
import 'package:fushi/utils.dart';

/// 浏览页「二级标签 + 横滑页面」（`_BrowseSwipeSections`）：只剩一个内容域时
/// （其余库模块被关掉，2026-10-05 移动端截图里只开了视频模块）不画那一排只有
/// 一个标签的页签——它既不能切换，又白占一行，还会被读成标题。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<void> pump(
    WidgetTester tester,
    List<String> labels, {
    Widget? trailing,
  }) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: debugBrowseSwipeSections<String>(
              tabs: <LibrarySectionTab<String>>[
                for (final String label in labels)
                  LibrarySectionTab<String>(value: label, label: label),
              ],
              selected: labels.first,
              trailing: trailing,
              pageBuilder: (String value) => Center(child: Text('page $value')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const Key picker = ValueKey<String>('debug-browse-swipe-sections');

  testWidgets('单域时不显示二级页签行，页面直接顶上来', (WidgetTester tester) async {
    await pump(tester, <String>['视频']);
    expect(find.byKey(picker), findsNothing);
    expect(find.byType(LibrarySectionTabs<String>), findsNothing);
    expect(find.text('page 视频'), findsOneWidget);
    // 页签行整行收起：页面区从顶边开始，不留一行空白。
    expect(tester.getTopLeft(find.byType(TabBarView)).dy, 0);
  });

  testWidgets('单域但有尾随动作时只留动作，不画页签', (WidgetTester tester) async {
    await pump(
      tester,
      <String>['漫画'],
      trailing: const SizedBox(
        key: ValueKey<String>('trailing-action'),
        width: 40,
        height: 40,
      ),
    );
    expect(find.byKey(picker), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('trailing-action')),
      findsOneWidget,
    );
  });

  testWidgets('多域时照常显示二级页签', (WidgetTester tester) async {
    await pump(tester, <String>['书', '漫画', '游戏', '视频']);
    expect(find.byKey(picker), findsOneWidget);
    for (final String label in <String>['书', '漫画', '游戏', '视频']) {
      expect(
        find.descendant(of: find.byKey(picker), matching: find.text(label)),
        findsOneWidget,
      );
    }
  });
}
