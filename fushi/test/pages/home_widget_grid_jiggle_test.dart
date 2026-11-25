// BUG-5444：首页编辑态的 Apple 抖动只在绘制层转动。旧实现（AnimatedBuilder +
// Transform.rotate）每帧让每块组件的整棵语义子树重算并下发、块内容整块重画，debug
// 实例主线程 100% 占满（语义常开的 Windows 上尤甚），编辑首页就「卡死」。
//
// 这里钉住：Apple 编辑态抖动持续出帧时，块内容零重画、零重建、零语义更新，而转角确实
// 在变；M3E 编辑态与关动效的 Apple 编辑态没有常驻 ticker、pumpAndSettle 能停。
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/home_widget_grid.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:material_ui/material_ui.dart';

const List<HomeWidgetItem> _items = <HomeWidgetItem>[
  HomeWidgetItem(HomeWidgetKind.continueHero, HomeWidgetSize(2, 2)),
  HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(1, 1)),
  HomeWidgetItem(HomeWidgetKind.srsReview, HomeWidgetSize(1, 1)),
  HomeWidgetItem(HomeWidgetKind.week, HomeWidgetSize(2, 1)),
];

class _Counters {
  int paints = 0;
  int builds = 0;
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.counters);

  final _Counters counters;

  @override
  void paint(Canvas canvas, Size size) {
    counters.paints++;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF8899AA),
    );
  }

  @override
  bool shouldRepaint(_CountingPainter old) => false;
}

class _Cell extends StatelessWidget {
  const _Cell({required this.slot, required this.counters});

  final String slot;
  final _Counters counters;

  @override
  Widget build(BuildContext context) {
    counters.builds++;
    return Semantics(
      label: 'cell $slot',
      child: CustomPaint(painter: _CountingPainter(counters)),
    );
  }
}

Future<_Counters> _pumpGrid(
  WidgetTester tester, {
  required bool apple,
  bool disableAnimations = false,
}) async {
  final _Counters counters = _Counters();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        designSystem: apple
            ? FushiDesignSystem.cupertino
            : FushiDesignSystem.material,
        glassDesign: apple,
      ),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: HomeWidgetGrid(
                items: _items,
                grid: HomeGridKind.compact,
                editing: true,
                cellBuilder: (BuildContext context, HomeWidgetItem item) =>
                    _Cell(slot: item.slot, counters: counters),
                labelOf: (HomeWidgetItem item) => item.slot,
                onEnterEdit: () {},
                onExitEdit: () {},
                onMove: (int from, int to) {},
                onRemove: (int index) {},
                onResize: (int index, HomeWidgetSize size) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return counters;
}

void main() {
  testWidgets('Apple 编辑态：抖动逐帧只换变换层，内容零重画 / 零重建 / 零语义更新', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final _Counters counters = await _pumpGrid(tester, apple: true);
    // 进场错峰与首帧烘焙走完。
    for (int i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final Iterable<RenderHomeWidgetJiggle> jiggles = tester
        .renderObjectList<RenderHomeWidgetJiggle>(
          find.byType(HomeWidgetJiggle),
        );
    expect(jiggles, hasLength(_items.length));

    final SemanticsOwner owner =
        tester.binding.renderViews.first.owner!.semanticsOwner!;
    int semanticsUpdates = 0;
    void onUpdate() => semanticsUpdates++;
    owner.addListener(onUpdate);
    counters
      ..paints = 0
      ..builds = 0;

    final Set<double> angles = <double>{};
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      angles.add(jiggles.first.angle);
    }
    owner.removeListener(onUpdate);

    // 抖动确实在转（常驻 ticker 照常出帧）。
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(angles.length, greaterThan(10));
    // 但只有变换层在变。
    expect(counters.paints, 0, reason: '块内容逐帧重画');
    expect(counters.builds, 0, reason: '块内容逐帧重建');
    expect(semanticsUpdates, 0, reason: '抖动逐帧触发语义更新');
    semantics.dispose();
  });

  testWidgets('M3E 编辑态：没有抖动、没有常驻 ticker，pumpAndSettle 能停', (
    WidgetTester tester,
  ) async {
    await _pumpGrid(tester, apple: false);
    await tester.pumpAndSettle();
    expect(find.byType(HomeWidgetJiggle), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('Apple 编辑态关动效：不抖、不歪、pumpAndSettle 能停', (
    WidgetTester tester,
  ) async {
    await _pumpGrid(tester, apple: true, disableAnimations: true);
    await tester.pumpAndSettle();
    expect(find.byType(HomeWidgetJiggle), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
