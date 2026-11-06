// WJP1eLSfdx（Wn1SZdlyhl 的复发）：手机横屏在播放器侧边栏「控制按钮」页拖按钮，
// 拖到视口边缘时页面不滚。BUG-3985 的回归测试只把编辑器嵌在裸 ListView 里，
// 没覆盖真实宿主（侧边栏设置面板：TabBarView 分页 + 每页 SingleChildScrollView）。
// 这里用真实面板 + 真实指针手势复现。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/controls/control_layout.dart' show ControlDragData;
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/settings/settings_destination.dart' show VideoGroup;

import '../../helpers/video_quick_settings_harness.dart';

bool _isChip(Widget w) =>
    w is Draggable<ControlDragData<VideoControlSlot, VideoControlItem>>;

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final ({String name, Offset start}) c in <({String name, Offset start})>[
    (name: '横向起手', start: const Offset(24, 0)),
    (name: '竖向起手（手机上往上拖）', start: const Offset(0, -24)),
  ]) {
    testWidgets('侧边栏控制按钮页（853x384）${c.name}：拖到视口顶边时页面回滚', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(853, 384));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoSheetHarness harness = await VideoSheetHarness.create();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 480,
                child: buildVideoSheetUnderTest(
                  harness: harness,
                  host: buildTestVideoHost(isTouchControls: true),
                  initialCategory: VideoGroup.controls.name,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder page = find.byKey(
        const PageStorageKey<String>('video-settings-page-controls'),
      );
      expect(page, findsOneWidget);
      final ScrollableState scrollable = tester.state<ScrollableState>(
        find.descendant(of: page, matching: find.byType(Scrollable)).first,
      );
      final Rect viewport = tester.getRect(page);
      // 把编辑器最靠下的一颗按钮（调色板末行）滚到视口下部：用户就是从这里往上拖。
      double lowest = double.negativeInfinity;
      for (final Element element
          in find.byWidgetPredicate(_isChip).evaluate()) {
        final RenderBox box = element.renderObject! as RenderBox;
        lowest = lowest < box.localToGlobal(box.size.center(Offset.zero)).dy
            ? box.localToGlobal(box.size.center(Offset.zero)).dy
            : lowest;
      }
      scrollable.position.jumpTo(
        (scrollable.position.pixels + lowest - (viewport.bottom - 40)).clamp(
          0,
          scrollable.position.maxScrollExtent,
        ),
      );
      await tester.pumpAndSettle();
      final double start = scrollable.position.pixels;
      expect(start, greaterThan(0), reason: '控制按钮页放不下一屏才有本问题');

      Offset? origin;
      final List<double> seen = <double>[];
      for (final Element element
          in find.byWidgetPredicate(_isChip).evaluate()) {
        final RenderBox box = element.renderObject! as RenderBox;
        final Offset center = box.localToGlobal(box.size.center(Offset.zero));
        seen.add(center.dy);
        final bool visible =
            center.dy > viewport.top + 80 && center.dy < viewport.bottom - 10;
        if (visible && (origin == null || center.dy > origin.dy)) {
          origin = center;
        }
      }
      expect(
        origin,
        isNotNull,
        reason: '视口里应有可拖的按钮；centers=$seen viewport=$viewport',
      );

      final TestGesture gesture = await tester.startGesture(origin!);
      await gesture.moveBy(c.start);
      await tester.pump();
      expect(
        find.byWidgetPredicate((Widget w) => w is Opacity && w.opacity == 0.3),
        findsOneWidget,
        reason: '拖动已开始（源 chip 变半透明占位）',
      );
      await gesture.moveTo(Offset(origin.dx, viewport.top + 6));
      await _pumpFrames(tester, 40);

      expect(
        scrollable.position.pixels,
        lessThan(start),
        reason: '拖到顶边应让控制按钮页回滚',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      final double settled = scrollable.position.pixels;
      await _pumpFrames(tester, 10);
      expect(scrollable.position.pixels, settled, reason: '松手后停止自动滚动');
    });
  }
}
