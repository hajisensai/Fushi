import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_top_bar_slots.dart';

/// 视频内顶栏三槽布局（[VideoTopBarSlots]）的行为守卫。
///
/// 原缺陷：顶栏是 media_kit fork 的一条 `Row`，左按钮组 / 标题 / 右按钮组各挂
/// `Flexible(flex: 1)` → `Flex` 把宽**平分**三份、`loose` 用不完的份额又不回流，
/// 右上角按钮组最多只拿到 1/3 顶栏宽，多出来的按钮被裁进横滚区；标题项关掉时旧代码
/// 返回 `Spacer()`，空白中段照旧霸占 1/3（「名称删空了、中间是空的，按钮还是被挡」）。
///
/// 现在按优先级分宽：左按钮 → 右按钮 → 标题吃剩余。下面每条都用**真实布局尺寸**断言，
/// 不是源码扫描。
void main() {
  const Key leftKey = Key('slot-left');
  const Key titleKey = Key('slot-title');
  const Key rightKey = Key('slot-right');

  Future<void> pumpBar(
    WidgetTester tester, {
    required double barWidth,
    required double leftWidth,
    required double rightWidth,
    Widget? title,
    double height = 48,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: barWidth,
            height: height,
            child: VideoTopBarSlots(
              left: SizedBox(key: leftKey, width: leftWidth, height: height),
              title: title ??
                  SizedBox(key: titleKey, width: barWidth, height: height),
              right: SizedBox(key: rightKey, width: rightWidth, height: height),
            ),
          ),
        ),
      ),
    );
  }

  group('顶栏三槽：按钮按需拿宽、标题吃剩余', () {
    testWidgets('右按钮组能拿到远超 1/3 顶栏宽的自身所需宽度', (WidgetTester tester) async {
      // 600 宽顶栏、右组需要 400（= 2/3）。旧的三等分 Flex 只会给 200。
      await pumpBar(
        tester,
        barWidth: 600,
        leftWidth: 60,
        rightWidth: 400,
      );

      expect(tester.getSize(find.byKey(rightKey)).width, 400,
          reason: '右按钮组必须足额拿到自身需要的宽，不被平分成 1/3（200）');
      expect(tester.getSize(find.byKey(leftKey)).width, 60);
      // 标题只吃剩余：600 - 60 - 400 = 140。
      expect(tester.getSize(find.byKey(titleKey)).width, 140,
          reason: '标题只拿两侧按钮用剩的宽');
    });

    testWidgets('右按钮组贴右边缘、左按钮组贴左边缘、标题接在左组之后', (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 600,
        leftWidth: 60,
        rightWidth: 400,
      );

      expect(tester.getTopLeft(find.byKey(leftKey)).dx, 0);
      expect(tester.getTopLeft(find.byKey(titleKey)).dx, 60);
      expect(tester.getTopRight(find.byKey(rightKey)).dx, 600,
          reason: 'topRight 组必须右对齐到顶栏右边缘');
    });

    testWidgets('标题槽为空时整条宽度都归按钮，不留霸占中段的空白占位', (WidgetTester tester) async {
      // 用户场景：把视频名称删空 / 关掉标题项 → 中段是空的，按钮不该再被挤。
      await pumpBar(
        tester,
        barWidth: 600,
        leftWidth: 60,
        rightWidth: 520,
        title: const SizedBox.shrink(key: titleKey),
      );

      expect(tester.getSize(find.byKey(rightKey)).width, 520,
          reason: '标题空了，右按钮组应能吃到 60 之外的全部宽');
      expect(tester.getSize(find.byKey(titleKey)).width, 0);
      expect(tester.getTopRight(find.byKey(rightKey)).dx, 600);
    });

    testWidgets('超长标题不得挤压按钮：按钮先拿够，标题被压成剩余宽', (WidgetTester tester) async {
      // 标题子树自身想要 10000 宽（模拟超长片名），仍只能拿剩余的 140。
      await pumpBar(
        tester,
        barWidth: 600,
        leftWidth: 60,
        rightWidth: 400,
        title: const SizedBox(key: titleKey, width: 10000, height: 48),
      );

      expect(tester.getSize(find.byKey(rightKey)).width, 400);
      expect(tester.getSize(find.byKey(titleKey)).width, 140,
          reason: '标题被剩余宽钳住（按钮优先于名称）');
      expect(tester.takeException(), isNull, reason: '超长标题不得造成溢出');
    });

    testWidgets('极窄顶栏：左组优先满足，右组吃掉剩下的全部，标题归零且不溢出', (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 300,
        leftWidth: 60,
        rightWidth: 400,
      );

      expect(tester.getSize(find.byKey(leftKey)).width, 60);
      expect(tester.getSize(find.byKey(rightKey)).width, 240,
          reason: '右组被钳到剩余的 240（组内自带横滚兜底可达性）');
      expect(tester.getSize(find.byKey(titleKey)).width, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('槽内子项垂直居中', (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 600,
        leftWidth: 60,
        rightWidth: 100,
        title: const SizedBox(key: titleKey, width: 100, height: 20),
        height: 48,
      );

      expect(tester.getTopLeft(find.byKey(titleKey)).dy, (48 - 20) / 2);
    });
  });
}
