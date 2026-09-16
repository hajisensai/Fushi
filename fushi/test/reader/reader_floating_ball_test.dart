import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';

/// 阅读器悬浮球：
/// - 几何：收起态球外缩停靠边、展开态回到视口内、按钮落在朝向屏幕中央的半圆弧上
///   （包围状）、半径随按钮数增长、贴近视口上下边时展开态沿边滑进来；
/// - 交互：收起态半透明且不画按钮 → 点球弧形展开 → 键回调打到动作 → 再点球收起；
///   拖到另一半屏松手换边并经 onDockChanged 落库；墨水屏零动画。
const Rect _viewport = Rect.fromLTWH(0, 40, 400, 700);

List<ReaderHeaderAction> _actions(List<String> log, {int count = 3}) {
  const List<IconData> icons = <IconData>[
    Icons.skip_previous_outlined,
    Icons.play_arrow_outlined,
    Icons.skip_next_outlined,
    Icons.replay_10_outlined,
    Icons.forward_10_outlined,
    Icons.link,
    Icons.tune_outlined,
  ];
  return <ReaderHeaderAction>[
    for (int i = 0; i < count; i++)
      ReaderHeaderAction(
        icon: icons[i],
        label: 'a$i',
        onPressed: () => log.add('a$i'),
      ),
  ];
}

Future<List<String>> _pump(
  WidgetTester tester, {
  int count = 3,
  ReaderFloatingBallDock dock = ReaderFloatingBallDock.right,
  double fraction = 0.5,
  void Function(ReaderFloatingBallDock, double)? onDockChanged,
  bool animate = true,
}) async {
  final List<String> log = <String>[];
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            ReaderFloatingBall(
              viewport: _viewport,
              actions: _actions(log, count: count),
              dock: dock,
              verticalFraction: fraction,
              animate: animate,
              onDockChanged: onDockChanged ?? (_, __) {},
            ),
          ],
        ),
      ),
    ),
  );
  return log;
}

Finder _ball() =>
    find.byKey(const ValueKey<String>('fushi_reader_floating_ball_icon'));

void main() {
  group('ReaderFloatingBallLayout', () {
    const ReaderFloatingBallLayout right = ReaderFloatingBallLayout(
      viewport: _viewport,
      dock: ReaderFloatingBallDock.right,
      verticalFraction: 0.5,
      actionCount: 3,
    );
    const ReaderFloatingBallLayout left = ReaderFloatingBallLayout(
      viewport: _viewport,
      dock: ReaderFloatingBallDock.left,
      verticalFraction: 0.5,
      actionCount: 3,
    );

    test('收起态球外缩停靠边、展开态整球回到视口内', () {
      expect(
        right.collapsedBallLeft + right.ballSize,
        closeTo(_viewport.right + right.tuck, 1e-9),
      );
      expect(
        right.expandedBallLeft + right.ballSize,
        closeTo(_viewport.right - right.margin, 1e-9),
      );
      expect(left.collapsedBallLeft, closeTo(_viewport.left - left.tuck, 1e-9));
      expect(
        left.expandedBallLeft,
        closeTo(_viewport.left + left.margin, 1e-9),
      );
      expect(
        right.tuck,
        lessThan(right.ballSize / 2),
        reason: '收起态至少露出一半球体，否则点不到',
      );
    });

    test('按钮落在朝向屏幕中央的半圆弧上：正上 → 正下均分，x 一律指向中央', () {
      expect(right.angleOf(0), closeTo(-math.pi / 2, 1e-9));
      expect(right.angleOf(1), closeTo(0, 1e-9));
      expect(right.angleOf(2), closeTo(math.pi / 2, 1e-9));
      for (int i = 0; i < 3; i++) {
        expect(
          right.buttonOffset(i).dx,
          lessThanOrEqualTo(1e-9),
          reason: '右停靠：按钮在球的左侧（屏幕中央方向）',
        );
        expect(
          left.buttonOffset(i).dx,
          greaterThanOrEqualTo(-1e-9),
          reason: '左停靠：按钮在球的右侧',
        );
      }
      // 中间那颗正对屏幕中央，离球心恰好一个半径。
      expect(right.buttonOffset(1).dx, closeTo(-right.radius, 1e-9));
      expect(right.buttonOffset(1).dy, closeTo(0, 1e-9));
      // 首尾两颗在球的正上 / 正下。
      expect(right.buttonOffset(0).dy, closeTo(-right.radius, 1e-9));
      expect(right.buttonOffset(2).dy, closeTo(right.radius, 1e-9));
    });

    test('半径随按钮数增长：相邻按钮中心距 ≥ 按钮直径 + 间距', () {
      for (final int n in <int>[1, 2, 3, 5, 7]) {
        final ReaderFloatingBallLayout l = ReaderFloatingBallLayout(
          viewport: _viewport,
          dock: ReaderFloatingBallDock.left,
          verticalFraction: 0.5,
          actionCount: n,
        );
        expect(
          l.radius,
          greaterThanOrEqualTo(l.ballSize / 2 + l.gap + l.buttonSize / 2),
          reason: 'n=$n 按钮至少离球一个 gap',
        );
        for (int i = 1; i < n; i++) {
          final double d = (l.buttonOffset(i) - l.buttonOffset(i - 1)).distance;
          expect(
            d,
            greaterThanOrEqualTo(l.buttonSize + l.gap - 1e-6),
            reason: 'n=$n 第 $i 颗与前一颗重叠',
          );
        }
      }
      const ReaderFloatingBallLayout seven = ReaderFloatingBallLayout(
        viewport: _viewport,
        dock: ReaderFloatingBallDock.left,
        verticalFraction: 0.5,
        actionCount: 7,
      );
      expect(seven.radius, greaterThan(right.radius));
    });

    test('包围盒只覆盖球 + 弧，球心落点与 dock 一致', () {
      expect(right.boxWidth, closeTo(right.ballSize / 2 + right.reach, 1e-9));
      expect(right.boxHeight, closeTo(right.reach * 2, 1e-9));
      expect(
        right.ballCenterInBox.dx,
        closeTo(right.boxWidth - right.ballSize / 2, 1e-9),
      );
      expect(left.ballCenterInBox.dx, closeTo(left.ballSize / 2, 1e-9));
      // 进度 1 时包围盒里的球心 = 展开态球位置。
      final Offset box = right.boxTopLeftAt(1);
      expect(
        box.dx + right.ballCenterInBox.dx,
        closeTo(right.expandedBallLeft + right.ballSize / 2, 1e-9),
      );
      expect(
        box.dy + right.ballCenterInBox.dy,
        closeTo(right.expandedBallTop + right.ballSize / 2, 1e-9),
      );
    });

    test('贴近视口上下边：展开态沿边滑到弧能放下的位置，收起态位置不变', () {
      const ReaderFloatingBallLayout top = ReaderFloatingBallLayout(
        viewport: _viewport,
        dock: ReaderFloatingBallDock.right,
        verticalFraction: 0,
        actionCount: 3,
      );
      expect(top.ballTop, closeTo(top.minTop, 1e-9));
      expect(top.expandedBallTop, greaterThan(top.ballTop));
      final double arcTop = top.expandedBallTop + top.ballSize / 2 - top.reach;
      expect(arcTop, greaterThanOrEqualTo(_viewport.top + top.margin - 1e-9));
      const ReaderFloatingBallLayout bottom = ReaderFloatingBallLayout(
        viewport: _viewport,
        dock: ReaderFloatingBallDock.right,
        verticalFraction: 1,
        actionCount: 3,
      );
      expect(bottom.expandedBallTop, lessThan(bottom.ballTop));
      final double arcBottom =
          bottom.expandedBallTop + bottom.ballSize / 2 + bottom.reach;
      expect(
        arcBottom,
        lessThanOrEqualTo(_viewport.bottom - bottom.margin + 1e-9),
      );
      // 中间位置不动。
      expect(right.expandedBallTop, closeTo(right.ballTop, 1e-9));
    });

    test('纵向比例夹在视口内并可反算；NaN 落中间', () {
      expect(right.fractionForTop(right.minTop - 100), 0);
      expect(right.fractionForTop(right.maxTop + 100), 1);
      expect(right.fractionForTop(right.ballTop), closeTo(0.5, 1e-9));
      const ReaderFloatingBallLayout nan = ReaderFloatingBallLayout(
        viewport: _viewport,
        dock: ReaderFloatingBallDock.right,
        verticalFraction: double.nan,
        actionCount: 3,
      );
      expect(nan.ballTop, closeTo(right.ballTop, 1e-9));
    });

    test('松手按球心所在半屏决定停靠边', () {
      expect(right.dockForBallLeft(10), ReaderFloatingBallDock.left);
      expect(right.dockForBallLeft(300), ReaderFloatingBallDock.right);
    });
  });

  testWidgets('收起态：Fushi 图标球、半透明、不画任何按钮；点球弧形展开三键、再点收起', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    expect(_ball(), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_outlined), findsNothing);
    expect(find.byIcon(Icons.play_arrow_outlined), findsNothing);
    expect(find.byIcon(Icons.skip_next_outlined), findsNothing);
    final Opacity idle = tester.widget<Opacity>(
      find.ancestor(of: _ball(), matching: find.byType(Opacity)).first,
    );
    expect(idle.opacity, kReaderFloatingBallIdleOpacity);
    expect(idle.opacity, lessThan(0.5), reason: '未激活要够透，不能遮正文');

    await tester.tap(_ball());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.skip_previous_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_outlined), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_outlined), findsOneWidget);
    final Opacity lit = tester.widget<Opacity>(
      find.ancestor(of: _ball(), matching: find.byType(Opacity)).first,
    );
    expect(lit.opacity, 1);
    // 右停靠、包围状：三颗都在球的左侧，首颗在球正上、中颗与球同高、末颗在球正下。
    final Offset ball = tester.getCenter(_ball());
    final Offset prev = tester.getCenter(
      find.byIcon(Icons.skip_previous_outlined),
    );
    final Offset play = tester.getCenter(
      find.byIcon(Icons.play_arrow_outlined),
    );
    final Offset next = tester.getCenter(find.byIcon(Icons.skip_next_outlined));
    expect(prev.dx, lessThanOrEqualTo(ball.dx + 1));
    expect(play.dx, lessThan(prev.dx), reason: '中颗离停靠边最远');
    expect(next.dx, lessThanOrEqualTo(ball.dx + 1));
    expect(prev.dy, lessThan(ball.dy));
    expect(play.dy, closeTo(ball.dy, 1));
    expect(next.dy, greaterThan(ball.dy));
    expect(prev.dx, closeTo(ball.dx, 1));
    expect(next.dx, closeTo(ball.dx, 1));

    await tester.tap(_ball());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.skip_previous_outlined), findsNothing);
    final Opacity again = tester.widget<Opacity>(
      find.ancestor(of: _ball(), matching: find.byType(Opacity)).first,
    );
    expect(again.opacity, kReaderFloatingBallIdleOpacity);
  });

  testWidgets('展开是错峰弹出：中途先起的键更靠近落点', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(_ball());
    // Ticker 首帧 elapsed = 0，先出一帧再推进；280ms 展开，90ms 时第 0 颗已明显
    // 飞出，最后一颗还基本贴着球。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final Offset ball = tester.getCenter(_ball());
    final double first =
        (tester.getCenter(find.byIcon(Icons.skip_previous_outlined)) - ball)
            .distance;
    final double last =
        (tester.getCenter(find.byIcon(Icons.skip_next_outlined)) - ball)
            .distance;
    expect(first, greaterThan(last));
    await tester.pumpAndSettle();
  });

  testWidgets('弧上按钮回调打到动作；按后保持展开', (WidgetTester tester) async {
    final List<String> log = await _pump(tester);
    await tester.tap(_ball());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.skip_previous_outlined));
    await tester.tap(find.byIcon(Icons.play_arrow_outlined));
    await tester.tap(find.byIcon(Icons.skip_next_outlined));
    await tester.pump();
    expect(log, <String>['a0', 'a1', 'a2']);
    expect(
      find.byIcon(Icons.play_arrow_outlined),
      findsOneWidget,
      reason: '按键不收起',
    );
  });

  testWidgets('七颗按钮：左停靠全在球右侧、互不重叠、都在视口内', (WidgetTester tester) async {
    await _pump(tester, count: 7, dock: ReaderFloatingBallDock.left);
    await tester.tap(_ball());
    await tester.pumpAndSettle();
    final Offset ball = tester.getCenter(_ball());
    final List<Rect> rects = <Rect>[
      for (final Element e in find.byType(InkWell).evaluate())
        tester.getRect(find.byWidget(e.widget)),
    ];
    expect(rects, hasLength(7));
    for (final Rect r in rects) {
      expect(r.center.dx, greaterThanOrEqualTo(ball.dx - 1));
      expect(r.top, greaterThanOrEqualTo(_viewport.top));
      expect(r.bottom, lessThanOrEqualTo(_viewport.bottom));
    }
    // 按钮是圆（CircleBorder 裁切），判重叠看圆心距 ≥ 直径，不看外接方框。
    for (int i = 0; i < rects.length; i++) {
      for (int j = i + 1; j < rects.length; j++) {
        expect(
          (rects[i].center - rects[j].center).distance,
          greaterThanOrEqualTo(kReaderFloatingBallButtonSize - 1e-6),
          reason: '第 $i / $j 颗重叠',
        );
      }
    }
  });

  testWidgets('拖到左半屏松手：换边吸附并回调落库；拖动会先收起', (WidgetTester tester) async {
    ReaderFloatingBallDock? dock;
    double? fraction;
    await _pump(
      tester,
      onDockChanged: (ReaderFloatingBallDock d, double f) {
        dock = d;
        fraction = f;
      },
    );
    await tester.tap(_ball());
    await tester.pumpAndSettle();
    final Offset from = tester.getCenter(_ball());
    await tester.drag(_ball(), Offset(-from.dx + 30, -200));
    await tester.pumpAndSettle();
    expect(dock, ReaderFloatingBallDock.left);
    expect(fraction, lessThan(0.5));
    expect(
      find.byIcon(Icons.skip_previous_outlined),
      findsNothing,
      reason: '拖动即收起',
    );
    final Rect ballRect = tester.getRect(_ball());
    expect(ballRect.center.dx, lessThan(_viewport.width / 2));
    expect(ballRect.top, greaterThanOrEqualTo(_viewport.top));
  });

  testWidgets('墨水屏模式（animate=false）：一帧完成展开', (WidgetTester tester) async {
    await _pump(tester, animate: false);
    await tester.tap(_ball());
    await tester.pump();
    expect(find.byIcon(Icons.skip_previous_outlined), findsOneWidget);
  });
}
