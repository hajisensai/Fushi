import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';
import 'package:hibiki/src/utils/components/galgame_poster_card.dart';
import 'package:hibiki/src/utils/components/shelf_card_widgets.dart';

/// TODO-2490：库页卡片标题「显示不全」——两行省略号之外必须有看全名的途径。
///
/// 共享件 [ShelfTitleOverflowTooltip] 只在标题真溢出 [Text] 的行数上限时挂
/// [Tooltip]（桌面悬停显示全名），不溢出时不添加任何节点；触屏路径的全名兜底
/// 是长按菜单 [MediaItemDialogFrame]（标题不限行）。测试字体 Ahem 每字符
/// 方块宽 = fontSize，行高 = fontSize，几何可精确推算。
void main() {
  const String longTitle = '魔法少女まどか☆マギカ劇場版総集編前編始まりの物語後編永遠の物語完全生産限定版';
  const String shortTitle = '短名';

  Widget host({required double width, required Widget child}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: child)),
      ),
    );
  }

  group('ShelfTitleOverflowTooltip', () {
    testWidgets('两行放不下的长标题挂 Tooltip，消息为完整标题', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          width: 140,
          child: const ShelfTitleOverflowTooltip(
            title: longTitle,
            style: TextStyle(fontSize: 14),
            maxLines: 2,
            child: Text(
              longTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      );
      final Tooltip tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, longTitle, reason: '悬停气泡必须给出完整标题，不是截断后的那份');
      expect(tooltip.triggerMode, TooltipTriggerMode.manual,
          reason: '不得注册点按/长按识别器与卡片手势抢竞技场');
      // 标题真渲染成两行（完整前缀可见），不是单行省略：Ahem 行高 = fontSize，
      // 两行高度必然超过 1.5 倍行高。
      final Size textSize = tester.getSize(find.text(longTitle));
      expect(textSize.height, greaterThan(14 * 1.5),
          reason: '长标题必须完整换行到第二行，而非单行省略');
    });

    // 真正的功能守卫：只断言 Tooltip 节点存在 + message 正确是假绿——那只证明
    // 挂上了，没证明「桌面悬停能看到全名」。这里驱动真实鼠标指针 hover 到标题上，
    // 断言 overlay 里确实弹出了带完整标题的气泡（此时 longTitle 在树上出现两处：
    // 卡上省略号截断的那份 + overlay 气泡里的那份）。
    testWidgets('鼠标悬停在溢出标题上真弹出全名气泡（manual 不挡 hover）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          width: 140,
          child: const ShelfTitleOverflowTooltip(
            title: longTitle,
            style: TextStyle(fontSize: 14),
            maxLines: 2,
            child: Text(
              longTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      );
      expect(find.text(longTitle), findsOneWidget, reason: '悬停前只有卡上截断的那份标题');

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text(longTitle)));
      // Tooltip 的 waitDuration/淡入动画走完。
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(longTitle), findsNWidgets(2),
          reason: '悬停后 overlay 必须多出一份完整标题的气泡，否则桌面「看全名」是死的');
      final Tooltip tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, longTitle);

      await gesture.moveTo(Offset.zero);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(longTitle), findsOneWidget, reason: '移开鼠标后气泡应收起');
    });

    testWidgets('不溢出的短标题不挂 Tooltip', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          width: 140,
          child: const ShelfTitleOverflowTooltip(
            title: shortTitle,
            style: TextStyle(fontSize: 14),
            maxLines: 2,
            child: Text(
              shortTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      );
      expect(find.byType(Tooltip), findsNothing,
          reason: '放得下的标题不该有悬停气泡（零额外节点）');
    });
  });

  group('三库卡片标题接线', () {
    testWidgets('ShelfCardFooter 长书名溢出时可悬停看全名', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          width: 140,
          child: const SizedBox(
            height: 48,
            child: ShelfCardFooter(title: longTitle),
          ),
        ),
      );
      final Tooltip tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, longTitle);
    });

    testWidgets('GalgamePosterCard 长名溢出挂 Tooltip 且不吞卡片长按',
        (WidgetTester tester) async {
      int longPressed = 0;
      await tester.pumpWidget(
        host(
          width: 140,
          child: GalgamePosterCard(
            cover: const ColoredBox(color: Colors.black26),
            title: longTitle,
            onLongPress: () => longPressed++,
          ),
        ),
      );
      final Tooltip tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, longTitle);
      // triggerMode=manual 不注册长按识别器：标题区长按仍走卡片长按菜单。
      await tester.longPress(find.byType(Tooltip), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(longPressed, 1, reason: 'Tooltip 不得吃掉卡片的长按（长按菜单是触屏看全名路径）');
    });

    testWidgets('长按菜单 MediaItemDialogFrame 标题不限行显示全名',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MediaItemDialogFrame(
                title: longTitle,
                showLaunchAction: false,
              ),
            ),
          ),
        ),
      );
      final Text titleText = tester.widget<Text>(find.text(longTitle));
      expect(titleText.maxLines, isNull, reason: '弹窗是卡片长标题「看全名」的兜底路径，不得再截断');
      expect(titleText.overflow, isNot(TextOverflow.ellipsis));
    });
  });
}
