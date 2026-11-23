import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockSize;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show SliverFushiCoverBlocks;
import 'package:material_ui/material_ui.dart';

/// BUG-5253：色块布局 sliver 滚动时不得逐帧重跑格子的 builder。
///
/// [SliverLayoutBuilder] 每个滚动帧都拿到新的 `scrollOffset`，旧实现因此每帧交出
/// 新的 `SliverList.builder`，视口里每一格（整张视频 / 书 / 游戏卡）都在 UI 线程上
/// 重新 build。这里数每一格被构造的次数：只滚动时，已建好的格一次都不许重建。
void main() {
  Widget host({
    required ScrollController controller,
    required Map<int, int> builds,
    required double width,
    String tag = 'a',
  }) => MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: 600,
        child: CustomScrollView(
          controller: controller,
          slivers: <Widget>[
            SliverFushiCoverBlocks(
              itemCount: 120,
              itemBuilder:
                  (BuildContext context, int index, FushiCoverBlockSize size) {
                    builds[index] = (builds[index] ?? 0) + 1;
                    return ColoredBox(
                      key: ValueKey<String>('cell-$tag-$index'),
                      color: const Color(0xFF336699),
                    );
                  },
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('scrolling does not rebuild already-built cells', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final Map<int, int> builds = <int, int>{};
    await tester.pumpWidget(
      host(controller: controller, builds: builds, width: 900),
    );
    await tester.pumpAndSettle();
    expect(builds, isNotEmpty);

    // 小步滚动：每一步都是新的 SliverConstraints（scrollOffset 变了）。
    for (int i = 1; i <= 30; i++) {
      controller.jumpTo(i * 7.0);
      await tester.pump();
    }
    await tester.pumpAndSettle();

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

  testWidgets('width change and parent rebuild still rebuild cells', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final Map<int, int> builds = <int, int>{};
    await tester.pumpWidget(
      host(controller: controller, builds: builds, width: 900),
    );
    await tester.pumpAndSettle();
    expect(builds[0], 1);

    // 横轴宽度变了：排布要重算，格子重建。
    await tester.pumpWidget(
      host(controller: controller, builds: builds, width: 1300),
    );
    await tester.pumpAndSettle();
    expect(builds[0], greaterThan(1));

    // 父级换了新的 widget（新 itemBuilder 闭包）：新闭包必须生效。
    await tester.pumpWidget(
      host(controller: controller, builds: builds, width: 1300, tag: 'b'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('cell-b-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cell-a-0')), findsNothing);
  });
}
