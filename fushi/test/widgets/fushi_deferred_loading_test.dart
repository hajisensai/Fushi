import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_deferred_loading.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';

// 查词「假空态」修复的两块基石：
// ① 结果区三态判定——查询在途 / 去抖待发时是「加载中」，只有真的查完且为空才是「无结果」；
// ② 延迟加载层——150ms 内结束不露指示器（快查询不闪），露出后至少停 300ms 再淡出。
void main() {
  group('resolveQueryBodyState', () {
    test('查询在途、没有结果：加载中，不是无结果', () {
      expect(
        resolveQueryBodyState(
          hasResults: false,
          searching: true,
          queryPending: false,
        ),
        QueryBodyState.loading,
      );
    });

    test('输入已变、新查询还在去抖窗口里：旧的空结果不算数', () {
      expect(
        resolveQueryBodyState(
          hasResults: false,
          searching: false,
          queryPending: true,
        ),
        QueryBodyState.loading,
      );
    });

    test('查完且为空：无结果', () {
      expect(
        resolveQueryBodyState(
          hasResults: false,
          searching: false,
          queryPending: false,
        ),
        QueryBodyState.empty,
      );
    });

    test('手里有结果：查询中也继续展示（不清屏）', () {
      expect(
        resolveQueryBodyState(
          hasResults: true,
          searching: true,
          queryPending: true,
        ),
        QueryBodyState.results,
      );
    });
  });

  Widget host(bool active) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 300,
        height: 300,
        child: FushiDeferredLoading(active: active, background: Colors.white),
      ),
    ),
  );

  Finder indicator() => find.byType(FushiLoadingView);
  Finder layer() => find.descendant(
    of: find.byType(FushiDeferredLoading),
    matching: find.byType(ColoredBox),
  );

  testWidgets('150ms 内结束：指示器从不露出，层立即撤掉', (WidgetTester tester) async {
    await tester.pumpWidget(host(true));
    expect(layer(), findsOneWidget, reason: '底色立即铺上（盖住空载 WebView）');
    expect(indicator(), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(indicator(), findsNothing);
    await tester.pumpWidget(host(false));
    expect(layer(), findsNothing);
    expect(indicator(), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(indicator(), findsNothing);
  });

  testWidgets('露出后至少停 300ms 再淡出', (WidgetTester tester) async {
    await tester.pumpWidget(host(true));
    await tester.pump(kDeferredLoadingDelay);
    expect(indicator(), findsOneWidget);
    // 露出 50ms 后查询就结束了。
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(host(false));
    await tester.pump(const Duration(milliseconds: 200));
    expect(indicator(), findsOneWidget, reason: '露出才 250ms，还得停');
    // 满 300ms 后开始淡出，淡出 150ms 后整层撤掉。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(kDeferredLoadingFade);
    await tester.pump();
    expect(indicator(), findsNothing);
    expect(layer(), findsNothing);
  });

  testWidgets('撤掉后不拦指针（盖在查词 WebView 上不能吞点击）', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                ),
              ),
              const Positioned.fill(
                child: FushiDeferredLoading(
                  active: false,
                  background: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tapAt(const Offset(100, 100));
    expect(taps, 1);
  });
}
