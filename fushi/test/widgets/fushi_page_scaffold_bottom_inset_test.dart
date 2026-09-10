import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// BUG-2440：页面脚手架的底部安全区（iOS home indicator / Android 手势条）。
///
/// 两条诉求必须**同时**成立，缺一条就是原来那个 bug 或它的反面：
///   ① body 的 viewport 要一直铺到屏幕最底——否则被扣掉的那段是一条谁也用不了的底色
///      空白，滚动内容在切线处被拦腰截断（用户 2026-09-10 录屏：设置 › 查词，卡片边框
///      和文字被切一半，怎么滚都进不去）。
///   ② 滚动到底时最后一项要完整可见——否则只是把「空白」换成了「末项被手势条压住」。
///
/// ① 由脚手架的 `SafeArea(bottom: false)` 保证，② 由 body 自己用
/// [withBottomSafeInset] 把 inset 补进滚动 padding 保证。两条各测一次。
void main() {
  const double screenWidth = 402;
  const double screenHeight = 874;
  const double bottomInset = 34; // iPhone home indicator

  /// 模拟一台有手势条的手机。逻辑尺寸靠 physicalSize / dpr 得出，所以
  /// physicalSize 要自己乘 dpr（写逻辑值会得到 1/3 大的屏，满屏 overflow）。
  void useHandsetView(WidgetTester tester) {
    tester.view.physicalSize = const Size(screenWidth * 3, screenHeight * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Widget hostPage(Widget body) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(screenWidth, screenHeight),
            devicePixelRatio: 3.0,
            padding: EdgeInsets.only(top: 59, bottom: bottomInset),
            viewPadding: EdgeInsets.only(top: 59, bottom: bottomInset),
          ),
          child: FushiPageScaffold(title: 'Lookup', body: body),
        ),
      );

  testWidgets(
    'page body extends under the bottom safe area instead of being clipped above it',
    (WidgetTester tester) async {
      useHandsetView(tester);
      await tester.pumpWidget(
        hostPage(
          ListView.builder(
            itemCount: 40,
            itemBuilder: (BuildContext context, int index) =>
                SizedBox(height: 60, child: Text('row $index')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byType(ListView)).bottom,
        screenHeight,
        reason:
            'SafeArea(bottom: true) 会把 viewport 切在 $screenHeight - $bottomInset，'
            '留下一条谁也用不了的底色空白，滚动内容在切线处被拦腰截断（BUG-2440）',
      );
    },
  );

  testWidgets(
    'scroll padding built with withBottomSafeInset keeps the last row clear of the gesture bar',
    (WidgetTester tester) async {
      useHandsetView(tester);
      const double basePadding = 16;
      await tester.pumpWidget(
        hostPage(
          Builder(
            builder: (BuildContext context) => ListView.builder(
              // 页面显式传 padding 时 Flutter 不再自动套 MediaQuery.padding，
              // 必须自己补——这正是本 helper 存在的理由。
              padding: withBottomSafeInset(
                context,
                const EdgeInsets.all(basePadding),
              ),
              itemCount: 40,
              itemBuilder: (BuildContext context, int index) =>
                  SizedBox(height: 60, child: Text('row $index')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 滚到底：末项底边必须停在手势条之上，且还要留出原有的 16 呼吸位。
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.text('row 39')).bottom,
        lessThanOrEqualTo(screenHeight - bottomInset - basePadding),
        reason: '末项被 home indicator 压住的话，这次修复只是把空白换成了遮挡',
      );
    },
  );

  testWidgets('withBottomSafeInset adds to the base padding, never replaces it',
      (WidgetTester tester) async {
    late EdgeInsets resolved;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(bottom: bottomInset),
        ),
        child: Builder(
          builder: (BuildContext context) {
            resolved = withBottomSafeInset(
              context,
              const EdgeInsets.fromLTRB(8, 12, 8, 20),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    // 相加而不是取 max：base 是内容之间的呼吸位，inset 是被手势条吃掉的不可用区，
    // 两段各自成立（与 BUG-383「逐边 max」的口径**故意**不同，语义不同）。
    expect(resolved, const EdgeInsets.fromLTRB(8, 12, 8, 20 + bottomInset));
  });

  testWidgets(
      'no bottom inset on a desktop-shaped view leaves padding untouched',
      (WidgetTester tester) async {
    late EdgeInsets resolved;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (BuildContext context) {
            resolved = withBottomSafeInset(context, const EdgeInsets.all(24));
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(resolved, const EdgeInsets.all(24));
  });
}
