import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_sliver_width_builder.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5253：[FushiSliverWidthBuilder] 只按横轴宽度重跑 builder。
///
/// [SliverLayoutBuilder] 每个滚动帧都拿到新的 `scrollOffset`，builder 交出新的
/// `SliverGrid` / `SliverList` 后视口里每一格逐帧重新 build。这里数 builder 与
/// 每一格的构造次数：只滚动时两者都不许增加；宽度、父级换新实例、builder 依赖的
/// InheritedWidget 变了时必须重建。
void main() {
  /// 被测 sliver：同一实例跨多次 pump 复用，才能把「父级换新实例」与「只有
  /// InheritedWidget 变了」分开测。
  Widget sliverUnderTest({
    required List<double> builderCalls,
    required Map<int, int> cellBuilds,
    String tag = 'a',
  }) => FushiSliverWidthBuilder(
    builder: (BuildContext context, double crossAxisExtent) {
      builderCalls.add(crossAxisExtent);
      final double scale = MediaQuery.textScalerOf(context).scale(1);
      final int columns = (crossAxisExtent / 150).floor().clamp(1, 64);
      return SliverGrid.builder(
        itemCount: 400,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: 80 * scale,
        ),
        itemBuilder: (BuildContext context, int index) {
          cellBuilds[index] = (cellBuilds[index] ?? 0) + 1;
          return ColoredBox(
            key: ValueKey<String>('cell-$tag-$index'),
            color: const Color(0xFF336699),
          );
        },
      );
    },
  );

  Widget host({
    required ScrollController controller,
    required Widget sliver,
    required double width,
    double textScale = 1,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: 600,
          child: CustomScrollView(
            controller: controller,
            slivers: <Widget>[sliver],
          ),
        ),
      ),
    ),
  );

  testWidgets('scrolling reruns neither the builder nor built cells', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<double> calls = <double>[];
    final Map<int, int> builds = <int, int>{};
    final Widget sliver = sliverUnderTest(
      builderCalls: calls,
      cellBuilds: builds,
    );
    await tester.pumpWidget(
      host(controller: controller, sliver: sliver, width: 500),
    );
    await tester.pumpAndSettle();
    expect(calls, <double>[500]);
    expect(builds, isNotEmpty);

    // 小步滚动 30 帧：每一步都是新的 SliverConstraints（scrollOffset 变了）。
    for (int i = 1; i <= 30; i++) {
      controller.jumpTo(i * 7.0);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(calls, <double>[500], reason: 'builder reran on scroll only');
    final List<int> rebuilt = <int>[
      for (final MapEntry<int, int> e in builds.entries)
        if (e.value > 1) e.key,
    ];
    expect(
      rebuilt,
      isEmpty,
      reason: 'cells rebuilt while only the scroll offset changed: $builds',
    );
  });

  testWidgets('width, parent and inherited changes still rebuild', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<double> calls = <double>[];
    final Map<int, int> builds = <int, int>{};
    Widget sliver = sliverUnderTest(builderCalls: calls, cellBuilds: builds);
    Future<void> pump({required double width, double textScale = 1}) async {
      await tester.pumpWidget(
        host(
          controller: controller,
          sliver: sliver,
          width: width,
          textScale: textScale,
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(width: 500);
    expect(calls.last, 500);
    expect(builds[0], 1);

    // 横轴宽度变了：builder 拿到新宽度，格子重建。
    await pump(width: 700);
    expect(calls.last, 700);
    expect(builds[0], greaterThan(1));

    // 同一实例、同一宽度再 pump：builder 不重跑。
    final int settled = calls.length;
    await pump(width: 700);
    expect(calls.length, settled);

    // 父级换了新的 widget（新 builder 闭包）：新闭包必须生效。
    sliver = sliverUnderTest(builderCalls: calls, cellBuilds: builds, tag: 'b');
    await pump(width: 700);
    expect(find.byKey(const ValueKey<String>('cell-b-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cell-a-0')), findsNothing);

    // 同一实例、宽度不变，只有 builder 里读的 InheritedWidget 变了：必须按新值重排。
    final int before = calls.length;
    await pump(width: 700, textScale: 2);
    expect(calls.length, greaterThan(before));
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('cell-b-0'))).height,
      160,
    );
  });
}
