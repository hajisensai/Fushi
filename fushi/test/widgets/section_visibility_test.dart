// HBK-AUDIT-017：隐藏的保活库页仍参与焦点和返回。
//
// Offstage + TickerMode 不管焦点与返回：藏起来的书架在多选模式下仍以
// `canPop: false` 拦住返回键，回调还在看不见的地方退出多选；藏起来的视图里的
// 焦点节点仍可被 Tab 遍历到。SectionVisibilityScope / SectionPopScope 在分区
// 可见性层统一裁剪这两种资格。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';

void main() {
  Future<void> pumpPushed(
    WidgetTester tester, {
    required bool outerVisible,
    required bool innerVisible,
    required VoidCallback onIntercept,
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
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(intercepted, 0);
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('隐藏分区排除焦点', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SectionVisibilityScope(
            visible: false,
            child: TextField(key: ValueKey<String>('hidden')),
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
  });

  // 迁自 Codex 第五轮复现 section_visibility_ancestor_focus_repro.dart：外层
  // tab（HomePage 保活层）隐藏、库页壳里本地「当前」视图 visible:true 时，
  // 子树不能持焦点、不能吃按键。
  for (final bool outerVisible in <bool>[true, false]) {
    testWidgets('外层可见=$outerVisible 决定内层当前视图的焦点与按键', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode(debugLabel: 'library-section-field');
      addTearDown(node.dispose);
      int keyDownCount = 0;
      bool? effectiveVisibility;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Offstage(
              offstage: !outerVisible,
              child: SectionVisibilityScope(
                visible: outerVisible,
                child: SectionVisibilityScope(
                  visible: true,
                  child: Builder(
                    builder: (BuildContext context) {
                      effectiveVisibility = SectionVisibility.of(context);
                      return Focus(
                        focusNode: node,
                        onKeyEvent: (FocusNode node, KeyEvent event) {
                          if (event is KeyDownEvent) keyDownCount++;
                          return KeyEventResult.handled;
                        },
                        child: const SizedBox(width: 200, height: 48),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      final bool hasFocus = node.hasFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(effectiveVisibility, outerVisible);
      expect(hasFocus, outerVisible);
      expect(keyDownCount, outerVisible ? 1 : 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('外层由隐转显后，内层当前视图重新可聚焦', (WidgetTester tester) async {
    final FocusNode node = FocusNode(debugLabel: 'reshown');
    addTearDown(node.dispose);
    Widget app(bool outer) => MaterialApp(
      home: Scaffold(
        body: SectionVisibilityScope(
          visible: outer,
          child: SectionVisibilityScope(
            visible: true,
            child: Focus(
              focusNode: node,
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(false));
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isFalse);
    await tester.pumpWidget(app(true));
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
  });
}
