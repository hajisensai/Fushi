// HBK-AUDIT-017：隐藏的保活库页仍参与焦点和返回。
//
// Offstage + TickerMode 不管焦点与返回：藏起来的书架在多选模式下仍以
// `canPop: false` 拦住返回键，回调还在看不见的地方退出多选；藏起来的视图里的
// 焦点节点仍可被 Tab 遍历到。SectionVisibilityScope / SectionPopScope 在分区
// 可见性层统一裁剪这两种资格。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';

void main() {
  Future<void> pumpPushed(
    WidgetTester tester, {
    required bool outerVisible,
    required bool innerVisible,
    required VoidCallback onIntercept,
    bool excludeFocus = true,
  }) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('root'))),
    );
    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator),
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: SectionVisibilityScope(
            visible: outerVisible,
            excludeFocus: excludeFocus,
            child: SectionVisibilityScope(
              visible: innerVisible,
              child: SectionPopScope(
                intercepting: true,
                onIntercept: onIntercept,
                child: const TextField(key: ValueKey<String>('field')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('可见分区的多选拦返回并回调', (WidgetTester tester) async {
    int intercepted = 0;
    await pumpPushed(
      tester,
      outerVisible: true,
      innerVisible: true,
      onIntercept: () => intercepted++,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(intercepted, 1);
    expect(find.byKey(const ValueKey<String>('field')), findsOneWidget);
  });

  testWidgets('隐藏分区的多选不拦返回、也不在背后回调', (WidgetTester tester) async {
    int intercepted = 0;
    await pumpPushed(
      tester,
      outerVisible: true,
      innerVisible: false,
      onIntercept: () => intercepted++,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(intercepted, 0);
    expect(find.text('root'), findsOneWidget, reason: '返回照常弹出路由');
  });

  testWidgets('外层 tab 隐藏时里面的「当前」视图同样不拦返回', (WidgetTester tester) async {
    int intercepted = 0;
    await pumpPushed(
      tester,
      outerVisible: false,
      innerVisible: true,
      onIntercept: () => intercepted++,
      excludeFocus: false,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(intercepted, 0);
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('隐藏分区排除焦点；excludeFocus: false 只发布可见性', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              SectionVisibilityScope(
                visible: false,
                child: TextField(key: ValueKey<String>('hidden')),
              ),
              SectionVisibilityScope(
                visible: false,
                excludeFocus: false,
                child: TextField(key: ValueKey<String>('host-managed')),
              ),
            ],
          ),
        ),
      ),
    );
    final EditableText hidden = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('hidden')),
        matching: find.byType(EditableText),
      ),
    );
    hidden.focusNode.requestFocus();
    await tester.pump();
    expect(hidden.focusNode.hasFocus, isFalse);

    final EditableText managed = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('host-managed')),
        matching: find.byType(EditableText),
      ),
    );
    managed.focusNode.requestFocus();
    await tester.pump();
    expect(managed.focusNode.hasFocus, isTrue);
  });
}
