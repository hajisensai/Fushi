import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';

/// 阅读器悬浮球：
/// - 几何：收起态球外缩停靠边、展开态回到视口内、按钮在球正上方竖排一列（与球
///   同轴、球在列最下方）、列高随按钮数增长、放不下时展开态沿边往下滑；视口矮到
///   一列装不下时向屏幕中央换列，球与每颗按钮都留在视口内；
/// - 交互：收起态半透明且不画按钮 → 点球竖排展开 → 键回调打到动作 → 再点球收起；
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
  Rect viewport = _viewport,
  Size screen = const Size(400, 800),
}) async {
  final List<String> log = <String>[];
  tester.view.physicalSize = screen;
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
              viewport: viewport,
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

/// [inner] 是否完整落在 [outer] 内（容 1e-6 浮点误差）。
bool _within(Rect inner, Rect outer) =>
    inner.left >= outer.left - 1e-6 &&
    inner.top >= outer.top - 1e-6 &&
    inner.right <= outer.right + 1e-6 &&
    inner.bottom <= outer.bottom + 1e-6;

Rect _expandedBallRect(ReaderFloatingBallLayout l) => Rect.fromLTWH(
  l.expandedBallLeft,
  l.expandedBallTop,
  l.ballSize,
  l.ballSize,
);

List<Rect> _expandedButtonRects(ReaderFloatingBallLayout l) {
  final Offset center = _expandedBallRect(l).center;
  return <Rect>[
    for (int i = 0; i < l.actionCount; i++)
      Rect.fromCenter(
        center: center + l.buttonOffset(i),
        width: l.buttonSize,
        height: l.buttonSize,
      ),
  ];
}

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

    test('按钮在球正上方竖排一列：与球同轴、列表顺序自上而下、末颗紧挨球', () {
      for (final ReaderFloatingBallLayout l in <ReaderFloatingBallLayout>[
        right,
        left,
      ]) {
        for (int i = 0; i < 3; i++) {
          expect(l.buttonOffset(i).dx, closeTo(0, 1e-9), reason: '与球同一竖轴');
          expect(l.buttonOffset(i).dy, lessThan(0), reason: '全部在球上方');
        }
      }
      // 末颗离球最近：球半径 + gap + 按钮半径。
      expect(
        right.buttonOffset(2).dy,
        closeTo(-(right.ballSize / 2 + right.gap + right.buttonSize / 2), 1e-9),
      );
      // 相邻两颗中心恰好隔一个按钮直径 + gap，自上而下。
      for (int i = 1; i < 3; i++) {
        expect(
          right.buttonOffset(i).dy - right.buttonOffset(i - 1).dy,
          closeTo(right.buttonSize + right.gap, 1e-9),
        );
      }
      // 列顶 = reach。
      expect(
        -right.buttonOffset(0).dy + right.buttonSize / 2,
        closeTo(right.reach, 1e-9),
      );
    });

    test('包围盒只覆盖球 + 按钮列，球在盒底', () {
      expect(right.boxWidth, closeTo(right.ballSize, 1e-9));
      expect(right.boxHeight, closeTo(right.reach + right.ballSize / 2, 1e-9));
      expect(right.ballCenterInBox.dx, closeTo(right.ballSize / 2, 1e-9));
      expect(
        right.ballCenterInBox.dy + right.ballSize / 2,
        closeTo(right.boxHeight, 1e-9),
      );
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

    test('贴近视口上边：展开态球往下滑到整列放得下；下边与中间位置不动', () {
      const ReaderFloatingBallLayout top = ReaderFloatingBallLayout(
        viewport: _viewport,
        dock: ReaderFloatingBallDock.right,
        verticalFraction: 0,
        actionCount: 3,
      );
      expect(top.ballTop, closeTo(top.minTop, 1e-9));
      expect(top.expandedBallTop, greaterThan(top.ballTop));
      final double columnTop =
          top.expandedBallTop + top.ballSize / 2 - top.reach;
      expect(
        columnTop,
        greaterThanOrEqualTo(_viewport.top + top.margin - 1e-9),
      );
      const ReaderFloatingBallLayout bottom = ReaderFloatingBallLayout(
        viewport: _viewport,
        dock: ReaderFloatingBallDock.right,
        verticalFraction: 1,
        actionCount: 3,
      );
      expect(bottom.expandedBallTop, closeTo(bottom.ballTop, 1e-9));
      expect(right.expandedBallTop, closeTo(right.ballTop, 1e-9));
    });

    test('视口放不下整列：换列后球与每颗按钮都完整落在视口内、也在包围盒内', () {
      for (final ReaderFloatingBallDock dock in ReaderFloatingBallDock.values) {
        for (final double fraction in <double>[0, 0.5, 1]) {
          final ReaderFloatingBallLayout crowded = ReaderFloatingBallLayout(
            viewport: const Rect.fromLTWH(0, 0, 400, 200),
            dock: dock,
            verticalFraction: fraction,
            actionCount: 7,
          );
          final String why = '$dock / $fraction';
          expect(crowded.columnCount, greaterThan(1), reason: why);
          final Rect ball = _expandedBallRect(crowded);
          expect(_within(ball, crowded.viewport), isTrue, reason: '球 $why');
          final Offset box = crowded.boxTopLeftAt(1);
          final Rect boxRect = Rect.fromLTWH(
            box.dx,
            box.dy,
            crowded.boxWidth,
            crowded.boxHeight,
          );
          for (final Rect r in _expandedButtonRects(crowded)) {
            expect(_within(r, crowded.viewport), isTrue, reason: '$r $why');
            expect(_within(r, boxRect), isTrue, reason: '包围盒 $r $why');
          }
        }
      }
    });

    test('横屏手机视口（高 280）放 6 颗：每列 4 颗、分两列，一列放得下时仍单列', () {
      const ReaderFloatingBallLayout landscape = ReaderFloatingBallLayout(
        viewport: Rect.fromLTWH(0, 40, 800, 280),
        dock: ReaderFloatingBallDock.left,
        verticalFraction: 0.5,
        actionCount: 6,
      );
      expect(landscape.perColumn, 4);
      expect(landscape.columnCount, 2);
      // 第一列自下而上是列表末四颗（离球近者先），第二列接着放前两颗。
      expect(landscape.buttonOffset(5).dx, closeTo(0, 1e-9));
      expect(landscape.buttonOffset(2).dx, closeTo(0, 1e-9));
      expect(landscape.buttonOffset(1).dx, closeTo(landscape.pitch, 1e-9));
      expect(landscape.buttonOffset(0).dx, closeTo(landscape.pitch, 1e-9));
      // 底对齐：第二列最下一颗与第一列末颗同高。
      expect(
        landscape.buttonOffset(1).dy,
        closeTo(landscape.buttonOffset(5).dy, 1e-9),
      );
      // 7 颗在 700 高视口：一列放得下，行为与单列完全一致。
      const ReaderFloatingBallLayout tall = ReaderFloatingBallLayout(
        viewport: _viewport,
        dock: ReaderFloatingBallDock.left,
        verticalFraction: 0.5,
        actionCount: 7,
      );
      expect(tall.columnCount, 1);
      expect(tall.boxWidth, closeTo(tall.ballSize, 1e-9));
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

  testWidgets('收起态：Fushi 图标球、半透明、不画任何按钮；点球竖排展开三键、再点收起', (
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
    // 竖排一列：三颗与球同轴，自上而下 prev → play → next，球在最下方。
    final Offset ball = tester.getCenter(_ball());
    final Offset prev = tester.getCenter(
      find.byIcon(Icons.skip_previous_outlined),
    );
    final Offset play = tester.getCenter(
      find.byIcon(Icons.play_arrow_outlined),
    );
    final Offset next = tester.getCenter(find.byIcon(Icons.skip_next_outlined));
    for (final Offset b in <Offset>[prev, play, next]) {
      expect(b.dx, closeTo(ball.dx, 1));
    }
    expect(prev.dy, lessThan(play.dy));
    expect(play.dy, lessThan(next.dy));
    expect(next.dy, lessThan(ball.dy), reason: '球在列的最下方');

    await tester.tap(_ball());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.skip_previous_outlined), findsNothing);
    final Opacity again = tester.widget<Opacity>(
      find.ancestor(of: _ball(), matching: find.byType(Opacity)).first,
    );
    expect(again.opacity, kReaderFloatingBallIdleOpacity);
  });

  testWidgets('展开是错峰弹出：离球近的先起、中途已飞得更接近落点', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(_ball());
    // Ticker 首帧 elapsed = 0，先出一帧再推进；280ms 展开，90ms 时末颗（紧挨球）
    // 已明显飞出，首颗（列顶）还基本贴着球。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    const ReaderFloatingBallLayout l = ReaderFloatingBallLayout(
      viewport: _viewport,
      dock: ReaderFloatingBallDock.right,
      verticalFraction: 0.5,
      actionCount: 3,
    );
    final Offset ball = tester.getCenter(_ball());
    double progress(IconData icon, int index) =>
        (tester.getCenter(find.byIcon(icon)) - ball).distance /
        l.buttonOffset(index).distance;
    expect(
      progress(Icons.skip_next_outlined, 2),
      greaterThan(progress(Icons.skip_previous_outlined, 0)),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('列中按钮回调打到动作；按后保持展开', (WidgetTester tester) async {
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

  testWidgets('七颗按钮：左停靠竖排与球同轴、互不重叠、都在视口内', (WidgetTester tester) async {
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
      expect(r.center.dx, closeTo(ball.dx, 1));
      expect(r.center.dy, lessThan(ball.dy));
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

  for (final ReaderFloatingBallDock dock in ReaderFloatingBallDock.values) {
    testWidgets('横屏手机视口高 280 + 六颗按钮（${dock.id} 停靠）：全在视口内、互不重叠、'
        '分两列以上、新列在屏幕中央一侧', (WidgetTester tester) async {
      const Rect landscape = Rect.fromLTWH(0, 40, 800, 280);
      final List<String> log = await _pump(
        tester,
        count: 6,
        dock: dock,
        fraction: 1,
        viewport: landscape,
        screen: const Size(800, 400),
      );
      await tester.tap(_ball());
      await tester.pumpAndSettle();
      final Rect ball = tester.getRect(_ball());
      expect(_within(ball, landscape), isTrue, reason: '球 $ball');
      final List<Rect> rects = <Rect>[
        for (final Element e in find.byType(InkWell).evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      expect(rects, hasLength(6));
      for (final Rect r in rects) {
        expect(_within(r, landscape), isTrue, reason: '按钮 $r 越出视口');
        expect(r.center.dy, lessThan(ball.center.dy), reason: '全部在球上方');
        if (dock == ReaderFloatingBallDock.left) {
          expect(r.center.dx, greaterThanOrEqualTo(ball.center.dx - 1));
        } else {
          expect(r.center.dx, lessThanOrEqualTo(ball.center.dx + 1));
        }
      }
      for (int i = 0; i < rects.length; i++) {
        for (int j = i + 1; j < rects.length; j++) {
          expect(
            (rects[i].center - rects[j].center).distance,
            greaterThanOrEqualTo(kReaderFloatingBallButtonSize - 1e-6),
            reason: '第 $i / $j 颗重叠',
          );
        }
      }
      final Set<int> columns = <int>{
        for (final Rect r in rects) r.center.dx.round(),
      };
      expect(columns.length, greaterThanOrEqualTo(2), reason: '应换列');
      // 第一列仍在球的竖轴上，其余列都在屏幕中央一侧。
      expect(columns, contains(ball.center.dx.round()));
      final double centerX = landscape.center.dx;
      for (final int x in columns) {
        expect(
          (x - centerX).abs(),
          lessThanOrEqualTo((ball.center.dx - centerX).abs() + 1),
          reason: '新列应朝屏幕中央展开',
        );
      }
      // 每颗都点得到。
      for (final Element e in find.byType(InkWell).evaluate().toList()) {
        await tester.tap(find.byWidget(e.widget));
      }
      await tester.pump();
      expect(log.toSet(), <String>{'a0', 'a1', 'a2', 'a3', 'a4', 'a5'});
    });
  }

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
