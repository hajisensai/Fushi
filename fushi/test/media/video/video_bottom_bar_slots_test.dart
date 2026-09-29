import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_bottom_bar_slots.dart';

/// BUG-2791：开右侧字幕列表后播放区变窄，底栏旧的三区 `Stack` 让居中传输簇与右簇
/// 叠画（「+10s」压在音量图标上）。这里用真布局钉住 [VideoBottomBarSlots]：
/// 宽时 play 仍在几何正中，窄时三区互不重叠。
void main() {
  group('videoBottomBarCenterStart', () {
    test('空间充裕时居中', () {
      expect(
        videoBottomBarCenterStart(
          width: 1000,
          leftWidth: 100,
          centerWidth: 300,
          rightWidth: 200,
        ),
        350,
      );
    });

    test('右簇宽到会被居中簇压住时，中簇左移贴住右簇左缘', () {
      expect(
        videoBottomBarCenterStart(
          width: 700,
          leftWidth: 100,
          centerWidth: 300,
          rightWidth: 250,
        ),
        150,
      );
    });

    test('左簇宽到会被压住时，中簇右移贴住左簇右缘', () {
      expect(
        videoBottomBarCenterStart(
          width: 700,
          leftWidth: 250,
          centerWidth: 300,
          rightWidth: 100,
        ),
        250,
      );
    });

    test('空隙不够时贴左簇右缘', () {
      expect(
        videoBottomBarCenterStart(
          width: 500,
          leftWidth: 100,
          centerWidth: 300,
          rightWidth: 200,
        ),
        100,
      );
    });
  });

  group('VideoBottomBarSlots 真布局', () {
    const Key leftKey = Key('left');
    const Key centerKey = Key('center');
    const Key rightKey = Key('right');

    Future<void> pumpBar(WidgetTester tester, double width) {
      // 默认测试视口只有 800 宽，会把更宽的底栏裁掉。
      tester.view.physicalSize = const Size(1200, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 48,
              child: const VideoBottomBarSlots(
                left: SizedBox(key: leftKey, width: 110, height: 20),
                // 截图里的传输簇：−10s / 上一句 / 播放 / 下一句 / +10s。
                center: SizedBox(key: centerKey, width: 330, height: 40),
                // 右簇：音量 / 倍速 / 自定义加号。
                right: SizedBox(key: rightKey, width: 180, height: 40),
              ),
            ),
          ),
        ),
      );
    }

    void expectNoOverlap(WidgetTester tester) {
      final Rect left = tester.getRect(find.byKey(leftKey));
      final Rect center = tester.getRect(find.byKey(centerKey));
      final Rect right = tester.getRect(find.byKey(rightKey));
      expect(left.right, lessThanOrEqualTo(center.left + 0.01));
      expect(center.right, lessThanOrEqualTo(right.left + 0.01));
    }

    testWidgets('宽底栏：play 所在的传输簇钉在几何正中', (WidgetTester tester) async {
      await pumpBar(tester, 1000);
      final Rect center = tester.getRect(find.byKey(centerKey));
      expect(center.center.dx, moreOrLessEquals(500));
      expect(center.width, 330);
      expectNoOverlap(tester);
    });

    testWidgets('开字幕列表挤窄：传输簇在两簇之间平移，不压右簇', (
      WidgetTester tester,
    ) async {
      // 110 + 330 + 180 = 620 放得下，但居中（x=160..490）会压进右簇（x=460 起）。
      await pumpBar(tester, 640);
      final Rect center = tester.getRect(find.byKey(centerKey));
      expect(center.width, 330);
      expectNoOverlap(tester);
      expect(
        tester.getRect(find.byKey(rightKey)).right,
        moreOrLessEquals(640),
      );
    });

    testWidgets('更窄：传输簇等比缩小塞进空隙，仍不重叠', (WidgetTester tester) async {
      await pumpBar(tester, 500);
      final Rect center = tester.getRect(find.byKey(centerKey));
      expect(center.width, lessThan(330));
      expectNoOverlap(tester);
    });
  });
}
