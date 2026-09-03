import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_top_bar_slots.dart';

/// 视频内顶栏布局（[VideoTopBarSlots]）的行为守卫。
///
/// 原缺陷（两处，同一个「名称挤按钮」病根）：
/// 1. 顶栏是 media_kit fork 的一条 `Row`，左按钮组 / 标题 / 右按钮组各挂
///    `Flexible(flex: 1)` → `Flex` 把宽**平分**三份、`loose` 用不完的份额又不回流，
///    右上角按钮组最多只拿到 1/3 顶栏宽，多出来的按钮被裁进横滚区；标题项关掉时旧代码
///    返回 `Spacer()`，空白中段照旧霸占 1/3（「名称删空了、中间是空的，按钮还是被挡」）。
/// 2. 标题被拖进左/右按钮槽时，它是组内一个固定 `maxWidth: 220` 的内联块，跟同组按钮
///    抢横向空间，把按钮挤进横滚区。
///
/// 现在按优先级分宽：四段按钮（左 lead/tail、右 lead/tail）→ 标题吃剩余。标题仍夹在
/// 它原来的按钮位置上显示，但**只分剩下的宽**。下面每条都用**真实布局尺寸**断言。
void main() {
  const Key leftLeadKey = Key('slot-left-lead');
  const Key leftTailKey = Key('slot-left-tail');
  const Key titleKey = Key('slot-title');
  const Key rightLeadKey = Key('slot-right-lead');
  const Key rightTailKey = Key('slot-right-tail');

  Future<void> pumpBar(
    WidgetTester tester, {
    required double barWidth,
    double leftLead = 0,
    double leftTail = 0,
    double rightLead = 0,
    double rightTail = 0,
    Widget? title,
    VideoTopBarTitlePlacement placement = VideoTopBarTitlePlacement.center,
    double height = 48,
  }) async {
    Widget slot(Key key, double width) => width == 0
        ? SizedBox.shrink(key: key)
        : SizedBox(key: key, width: width, height: height);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: barWidth,
            height: height,
            child: VideoTopBarSlots(
              leftLead: slot(leftLeadKey, leftLead),
              leftTail: slot(leftTailKey, leftTail),
              title: title ??
                  SizedBox(key: titleKey, width: barWidth, height: height),
              titlePlacement: placement,
              rightLead: slot(rightLeadKey, rightLead),
              rightTail: slot(rightTailKey, rightTail),
            ),
          ),
        ),
      ),
    );
  }

  group('顶栏：按钮按需拿宽、标题吃剩余', () {
    testWidgets('右按钮组能拿到远超 1/3 顶栏宽的自身所需宽度', (WidgetTester tester) async {
      // 600 宽顶栏、右组需要 400（= 2/3）。旧的三等分 Flex 只会给 200。
      await pumpBar(
        tester,
        barWidth: 600,
        leftLead: 60,
        rightLead: 400,
      );

      expect(tester.getSize(find.byKey(rightLeadKey)).width, 400,
          reason: '右按钮组必须足额拿到自身需要的宽，不被平分成 1/3（200）');
      expect(tester.getSize(find.byKey(leftLeadKey)).width, 60);
      // 标题只吃剩余：600 - 60 - 400 = 140。
      expect(tester.getSize(find.byKey(titleKey)).width, 140,
          reason: '标题只拿两侧按钮用剩的宽');
    });

    testWidgets('右按钮组贴右边缘、左按钮组贴左边缘、标题接在左段之后', (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 600,
        leftLead: 60,
        rightLead: 400,
      );

      expect(tester.getTopLeft(find.byKey(leftLeadKey)).dx, 0);
      expect(tester.getTopLeft(find.byKey(titleKey)).dx, 60);
      expect(tester.getTopRight(find.byKey(rightLeadKey)).dx, 600,
          reason: 'topRight 组必须右对齐到顶栏右边缘');
    });

    testWidgets('标题槽为空时整条宽度都归按钮，不留霸占中段的空白占位', (WidgetTester tester) async {
      // 用户场景：把视频名称删空 / 关掉标题项 → 中段是空的，按钮不该再被挤。
      await pumpBar(
        tester,
        barWidth: 600,
        leftLead: 60,
        rightLead: 520,
        title: const SizedBox.shrink(key: titleKey),
      );

      expect(tester.getSize(find.byKey(rightLeadKey)).width, 520,
          reason: '标题空了，右按钮组应能吃到 60 之外的全部宽');
      expect(tester.getSize(find.byKey(titleKey)).width, 0);
      expect(tester.getTopRight(find.byKey(rightLeadKey)).dx, 600);
    });

    testWidgets('超长标题不得挤压按钮：按钮先拿够，标题被压成剩余宽', (WidgetTester tester) async {
      // 标题子树自身想要 10000 宽（模拟超长片名），仍只能拿剩余的 140。
      await pumpBar(
        tester,
        barWidth: 600,
        leftLead: 60,
        rightLead: 400,
        title: const SizedBox(key: titleKey, width: 10000, height: 48),
      );

      expect(tester.getSize(find.byKey(rightLeadKey)).width, 400);
      expect(tester.getSize(find.byKey(titleKey)).width, 140,
          reason: '标题被剩余宽钳住（按钮优先于名称）');
      expect(tester.takeException(), isNull, reason: '超长标题不得造成溢出');
    });

    testWidgets('极窄顶栏：左段优先满足，右段吃掉剩下的全部，标题归零且不溢出', (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 300,
        leftLead: 60,
        rightLead: 400,
      );

      expect(tester.getSize(find.byKey(leftLeadKey)).width, 60);
      expect(tester.getSize(find.byKey(rightLeadKey)).width, 240,
          reason: '右段被钳到剩余的 240（段内自带横滚兜底可达性）');
      expect(tester.getSize(find.byKey(titleKey)).width, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('槽内子项垂直居中', (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 600,
        leftLead: 60,
        rightLead: 100,
        title: const SizedBox(key: titleKey, width: 100, height: 20),
        height: 48,
      );

      expect(tester.getTopLeft(find.byKey(titleKey)).dy, (48 - 20) / 2);
    });
  });

  group('标题被拖进按钮槽：位置保住，但宽度最后才分', () {
    testWidgets('标题落在 topRight 组中间：两段按钮先拿够，标题吃剩余且夹在中间',
        (WidgetTester tester) async {
      // 旧实现里标题是组内 220 宽的内联块，会把同组按钮挤进横滚区。
      await pumpBar(
        tester,
        barWidth: 600,
        leftLead: 60,
        rightLead: 200,
        rightTail: 100,
        placement: VideoTopBarTitlePlacement.right,
        title: const SizedBox(key: titleKey, width: 10000, height: 48),
      );

      expect(tester.getSize(find.byKey(rightLeadKey)).width, 200,
          reason: '标题前的那段按钮必须足额');
      expect(tester.getSize(find.byKey(rightTailKey)).width, 100,
          reason: '标题后的那段按钮必须足额');
      expect(tester.getSize(find.byKey(titleKey)).width, 240,
          reason: '标题只拿 600-60-200-100=240，不再是固定 220');

      // 显示顺序仍是 rightLead → title → rightTail，且整段贴右边缘。
      final double leadRight = tester.getTopRight(find.byKey(rightLeadKey)).dx;
      final double titleLeft = tester.getTopLeft(find.byKey(titleKey)).dx;
      final double titleRight = tester.getTopRight(find.byKey(titleKey)).dx;
      final double tailLeft = tester.getTopLeft(find.byKey(rightTailKey)).dx;
      expect(titleLeft, leadRight, reason: '标题紧跟它前面那段按钮');
      expect(tailLeft, titleRight, reason: '标题后面那段按钮紧跟标题');
      expect(tester.getTopRight(find.byKey(rightTailKey)).dx, 600,
          reason: '整个右段仍贴右边缘');
    });

    testWidgets('标题落在 topRight 时按钮永远优先：窄窗下标题归零，按钮一个不少',
        (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 320,
        leftLead: 60,
        rightLead: 160,
        rightTail: 100,
        placement: VideoTopBarTitlePlacement.right,
        title: const SizedBox(key: titleKey, width: 10000, height: 48),
      );

      expect(tester.getSize(find.byKey(rightLeadKey)).width, 160);
      expect(tester.getSize(find.byKey(rightTailKey)).width, 100);
      expect(tester.getSize(find.byKey(titleKey)).width, 0,
          reason: '宽度不够时先饿死标题，绝不裁按钮');
      expect(tester.takeException(), isNull);
    });

    testWidgets('标题落在 topLeft 组中间：夹在两段按钮之间，从左边缘起排',
        (WidgetTester tester) async {
      await pumpBar(
        tester,
        barWidth: 600,
        leftLead: 40,
        leftTail: 80,
        rightLead: 120,
        placement: VideoTopBarTitlePlacement.left,
        title: const SizedBox(key: titleKey, width: 10000, height: 48),
      );

      expect(tester.getSize(find.byKey(leftLeadKey)).width, 40);
      expect(tester.getSize(find.byKey(leftTailKey)).width, 80);
      expect(tester.getSize(find.byKey(rightLeadKey)).width, 120);
      expect(tester.getSize(find.byKey(titleKey)).width, 360,
          reason: '标题吃 600-40-80-120=360');

      expect(tester.getTopLeft(find.byKey(leftLeadKey)).dx, 0);
      expect(tester.getTopLeft(find.byKey(titleKey)).dx, 40,
          reason: '标题紧跟 lead 段');
      expect(tester.getTopLeft(find.byKey(leftTailKey)).dx, 400,
          reason: 'tail 段紧跟标题');
      expect(tester.getTopRight(find.byKey(rightLeadKey)).dx, 600);
    });
  });
}
