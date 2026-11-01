import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_push_aside_column.dart';

const Key _panelKey = ValueKey<String>('panel');
const Key _videoKey = ValueKey<String>('video');
const Duration _kDuration = Duration(milliseconds: 200);

/// Row[Expanded(画面), 侧栏列]，与视频页 `_videoWithSubtitlePanel` 同形。
class _Harness extends StatelessWidget {
  const _Harness({
    required this.open,
    required this.onBuildPanel,
    required this.onLayoutPanel,
    this.duration = _kDuration,
    this.width = 300,
  });

  final bool open;
  final VoidCallback onBuildPanel;
  final VoidCallback onLayoutPanel;
  final Duration duration;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Expanded(child: SizedBox(key: _videoKey)),
          VideoPushAsideColumn(
            open: open,
            width: width,
            duration: duration,
            builder: (BuildContext _) {
              onBuildPanel();
              return LayoutBuilder(
                key: _panelKey,
                builder: (BuildContext _, BoxConstraints c) {
                  onLayoutPanel();
                  return const ColoredBox(color: Color(0xFF123456));
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

void main() {
  group('VideoPushAsideColumn', () {
    late int builds;
    late int layouts;

    setUp(() {
      builds = 0;
      layouts = 0;
    });

    Widget harness(
      bool open, {
      Duration duration = _kDuration,
      double width = 300,
    }) => _Harness(
      open: open,
      duration: duration,
      width: width,
      onBuildPanel: () => builds++,
      onLayoutPanel: () => layouts++,
    );

    double videoWidth(WidgetTester tester) =>
        tester.getSize(find.byKey(_videoKey)).width;

    testWidgets('展开：列宽逐帧变，面板只 build / 排版一次', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(false));
      expect(find.byKey(_panelKey), findsNothing);
      expect(videoWidth(tester), 1000);

      await tester.pumpWidget(harness(true));
      final List<double> widths = <double>[];
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        widths.add(videoWidth(tester));
      }
      await tester.pumpAndSettle();

      expect(videoWidth(tester), 700);
      expect(widths.toSet().length, greaterThan(5), reason: '画面列应逐帧被挤窄');
      // 面板在整段动画里约束恒为 300 宽：不重建、不重排。
      expect(builds, 1);
      expect(layouts, 1);
      expect(tester.getSize(find.byKey(_panelKey)).width, 300);
    });

    testWidgets('收起：动画全程面板保留并画在收缩中的列里，结束才卸载（不露底色白条）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(true));
      expect(videoWidth(tester), 700);
      final int buildsBefore = builds;
      final int layoutsBefore = layouts;

      await tester.pumpWidget(harness(false));
      await tester.pump(const Duration(milliseconds: 60));
      // 收缩中：面板仍在树里、按完整宽度排版，左缘贴住收缩中的列左缘。
      expect(find.byKey(_panelKey), findsOneWidget);
      final double midVideo = videoWidth(tester);
      expect(midVideo, greaterThan(700));
      expect(midVideo, lessThan(1000));
      expect(tester.getTopLeft(find.byKey(_panelKey)).dx, midVideo);
      expect(tester.getSize(find.byKey(_panelKey)).width, 300);
      // 收起中的残影不接指针。
      final IgnorePointer ignore = tester.widget<IgnorePointer>(
        find.ancestor(
          of: find.byKey(_panelKey),
          matching: find.byType(IgnorePointer),
        ),
      );
      expect(ignore.ignoring, isTrue);

      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      expect(videoWidth(tester), 1000);
      // 收起过程同样不逐帧重建 / 重排面板（只有开关那一下的 build）。
      expect(builds - buildsBefore, 1);
      expect(layouts - layoutsBefore, 1);
    });

    testWidgets('时长为零（墨水屏 / 减弱动态效果）：直接到终态', (WidgetTester tester) async {
      await tester.pumpWidget(harness(false, duration: Duration.zero));
      await tester.pumpWidget(harness(true, duration: Duration.zero));
      await tester.pump();
      expect(find.byKey(_panelKey), findsOneWidget);
      await tester.pumpWidget(harness(false, duration: Duration.zero));
      await tester.pump();
      expect(find.byKey(_panelKey), findsNothing);
    });

    testWidgets('收起途中又打开：面板不重挂', (WidgetTester tester) async {
      await tester.pumpWidget(harness(true));
      final Element before = tester.element(find.byKey(_panelKey));
      await tester.pumpWidget(harness(false));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpWidget(harness(true));
      await tester.pumpAndSettle();
      expect(tester.element(find.byKey(_panelKey)), same(before));
    });
  });
}
