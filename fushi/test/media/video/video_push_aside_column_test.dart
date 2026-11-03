import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_push_aside_column.dart';

const Key _panelKey = ValueKey<String>('panel');
const Key _videoKey = ValueKey<String>('video');
const Duration _kDuration = Duration(milliseconds: 200);
const Color _kGap = Color(0xFF123456);

/// 与视频页 `_videoWithSubtitlePanel` 同形：[VideoPushAsideRow] 占满整行。
class _Harness extends StatelessWidget {
  const _Harness({
    required this.open,
    required this.onBuildPanel,
    required this.onLayoutPanel,
    required this.onTapVideo,
    this.duration = _kDuration,
    this.width = 300,
  });

  final bool open;
  final VoidCallback onBuildPanel;
  final VoidCallback onLayoutPanel;
  final VoidCallback onTapVideo;
  final Duration duration;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: VideoPushAsideRow(
        open: open,
        width: width,
        duration: duration,
        curve: Curves.easeOut,
        gapColor: _kGap,
        content: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTapVideo,
          child: const SizedBox.expand(key: _videoKey),
        ),
        builder: (BuildContext _) {
          onBuildPanel();
          return LayoutBuilder(
            key: _panelKey,
            builder: (BuildContext _, BoxConstraints c) {
              onLayoutPanel();
              return const ColoredBox(color: Color(0xFF654321));
            },
          );
        },
      ),
    );
  }
}

void main() {
  group('VideoPushAsideRow', () {
    late int builds;
    late int layouts;
    late int videoTaps;

    setUp(() {
      builds = 0;
      layouts = 0;
      videoTaps = 0;
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
      onTapVideo: () => videoTaps++,
    );

    void useView(WidgetTester tester, {double width = 1000}) {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    double videoWidth(WidgetTester tester) =>
        tester.getSize(find.byKey(_videoKey)).width;
    double panelLeft(WidgetTester tester) =>
        tester.getTopLeft(find.byKey(_panelKey)).dx;

    Finder gapBox() => find.byWidgetPredicate(
      (Widget w) => w is ColoredBox && w.color == _kGap,
    );

    testWidgets('展开：动画期间画面宽度冻结在满宽，结束一次性换成窄宽；面板只 build / 排版一次', (
      WidgetTester tester,
    ) async {
      useView(tester);
      await tester.pumpWidget(harness(false));
      expect(find.byKey(_panelKey), findsNothing);
      expect(videoWidth(tester), 1000);

      await tester.pumpWidget(harness(true));
      final List<double> videoWidths = <double>[];
      final List<double> panelLefts = <double>[];
      for (int i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        videoWidths.add(videoWidth(tester));
        panelLefts.add(panelLeft(tester));
      }
      expect(videoWidths.toSet(), <double>{1000}, reason: '动画期间画面不逐帧挤压');
      expect(panelLefts.toSet().length, greaterThan(5), reason: '面板仍逐帧滑入');

      await tester.pumpAndSettle();
      expect(videoWidth(tester), 700);
      expect(builds, 1);
      expect(layouts, 1);
      expect(tester.getSize(find.byKey(_panelKey)).width, 300);
    });

    testWidgets('展开中被面板盖住的那条画面不接点击（命中不越过画面格）', (WidgetTester tester) async {
      useView(tester);
      await tester.pumpWidget(harness(false));
      await tester.pumpWidget(harness(true));
      await tester.pump(const Duration(milliseconds: 100));
      final double left = panelLeft(tester);
      expect(left, lessThan(1000));
      expect(videoWidth(tester), 1000);

      await tester.tapAt(Offset((left + 1000) / 2, 300));
      expect(videoTaps, 0, reason: '面板区域的点击不能落到冻结的画面上');
      await tester.tapAt(Offset(left / 2, 300));
      expect(videoTaps, 1);
      await tester.pumpAndSettle();
    });

    testWidgets('收起：画面冻结在窄宽，与滑出中的列之间由面板底色填满（不露底），结束一次性还原满宽', (
      WidgetTester tester,
    ) async {
      useView(tester);
      await tester.pumpWidget(harness(true));
      expect(videoWidth(tester), 700);
      final int buildsBefore = builds;
      final int layoutsBefore = layouts;

      await tester.pumpWidget(harness(false));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(videoWidth(tester), 700, reason: '收起动画期间画面不逐帧变宽');
        expect(find.byKey(_panelKey), findsOneWidget);
        final double left = panelLeft(tester);
        expect(left, greaterThanOrEqualTo(700));
        // 画面右缘到面板左缘之间整条被底色块覆盖，没有空白。
        final Rect gap = tester.getRect(gapBox());
        expect(gap.left, 700);
        expect(gap.right, closeTo(left, 0.001));
        expect(gap.top, 0);
        expect(gap.bottom, 600);
      }
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
      expect(tester.getSize(gapBox()).width, 0);
      expect(builds - buildsBefore, 1);
      expect(layouts - layoutsBefore, 1);
    });

    testWidgets('时长为零（墨水屏 / 减弱动态效果）：直接到终态', (WidgetTester tester) async {
      useView(tester);
      await tester.pumpWidget(harness(false, duration: Duration.zero));
      await tester.pumpWidget(harness(true, duration: Duration.zero));
      await tester.pump();
      expect(find.byKey(_panelKey), findsOneWidget);
      expect(videoWidth(tester), 700);
      await tester.pumpWidget(harness(false, duration: Duration.zero));
      await tester.pump();
      expect(find.byKey(_panelKey), findsNothing);
      expect(videoWidth(tester), 1000);
    });

    testWidgets('收起途中又打开：画面全程不跳（保持最初冻结的宽度），面板不重挂', (WidgetTester tester) async {
      useView(tester);
      await tester.pumpWidget(harness(true));
      final Element before = tester.element(find.byKey(_panelKey));
      await tester.pumpWidget(harness(false));
      await tester.pump(const Duration(milliseconds: 80));
      expect(videoWidth(tester), 700);
      await tester.pumpWidget(harness(true));
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(videoWidth(tester), 700);
      }
      await tester.pumpAndSettle();
      expect(videoWidth(tester), 700);
      expect(tester.element(find.byKey(_panelKey)), same(before));
    });

    testWidgets('动画途中窗口尺寸变化：放弃冻结，画面按实际宽度排版', (WidgetTester tester) async {
      useView(tester);
      await tester.pumpWidget(harness(false));
      await tester.pumpWidget(harness(true));
      await tester.pump(const Duration(milliseconds: 60));
      expect(videoWidth(tester), 1000);

      tester.view.physicalSize = const Size(1200, 600);
      await tester.pump();
      final double cell = panelLeft(tester);
      expect(videoWidth(tester), closeTo(cell, 0.001));
      expect(videoWidth(tester), lessThan(1200));
      // 本段动画此后不再冻结：剩余帧画面随列宽走。
      await tester.pump(const Duration(milliseconds: 40));
      expect(videoWidth(tester), closeTo(panelLeft(tester), 0.001));
      await tester.pumpAndSettle();
      expect(videoWidth(tester), 900);
    });

    testWidgets('动画途中面板宽度变化（拖拽把手）：放弃冻结', (WidgetTester tester) async {
      useView(tester);
      await tester.pumpWidget(harness(false));
      await tester.pumpWidget(harness(true));
      await tester.pump(const Duration(milliseconds: 60));
      expect(videoWidth(tester), 1000);

      await tester.pumpWidget(harness(true, width: 350));
      expect(videoWidth(tester), closeTo(panelLeft(tester), 0.001));
      await tester.pumpAndSettle();
      expect(videoWidth(tester), 650);
    });

    testWidgets('静止时窗口变化照常生效（冻结只针对开 / 关动画）', (WidgetTester tester) async {
      useView(tester);
      await tester.pumpWidget(harness(true));
      expect(videoWidth(tester), 700);
      tester.view.physicalSize = const Size(1400, 600);
      await tester.pump();
      expect(videoWidth(tester), 1100);
    });
  });
}
