import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_background_tasks_scope.dart';
import 'package:fushi/src/pages/implementations/home_collage_widgets.dart';
import 'package:fushi/src/sync/background_tasks_indicator.dart'
    show BackgroundTask;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, FushiCoverBlockSize;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show kFushiCoverBlockHeroHeight;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiTextButton;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 首页拼贴版式（设计稿 H1–H8）的排版组件。
///
/// - BUG-4903（H4）：桌面「继续」右侧的卡被窗口切掉一半——旧版是「首块 + 两行
///   半高卡横滑」，横滑条铺到内容区外、最后一列总是被视口切在窗口边。新网格按
///   可用宽度算列数，任何宽度下每一块都完整落在内容区里，放不下的进「全部 ›」。
/// - BUG-4902（H3）：首页不再挂右下的「后台任务」FAB，同步状态改画在头像外圈。
void main() {
  group('HomeContinueGrid（H4）', () {
    test('列数随可用宽度增加、夹在 1…最大列数', () {
      int last = 0;
      for (final double w in <double>[820, 900, 1000, 1200, 1600, 2400]) {
        final int c = homeContinueGridColumns(width: w);
        expect(c, inInclusiveRange(1, kHomeContinueGridMaxColumns));
        expect(c, greaterThanOrEqualTo(last));
        last = c;
      }
      // 设计稿桌面内容宽（约 890）是首块 + 3 列。
      expect(homeContinueGridColumns(width: 890), 3);
    });

    test('画出来的条数 = 首块 + 两行，少于一格时就是全部', () {
      expect(homeContinueGridVisibleCount(width: 890, itemCount: 12), 7);
      expect(homeContinueGridVisibleCount(width: 890, itemCount: 4), 4);
    });

    for (final double width in <double>[820, 1000, 1366, 1920]) {
      testWidgets('宽 $width：每块完整落在内容区里，首块是 hero', (WidgetTester tester) async {
        // 测试视口默认 800 宽：不放大的话 SizedBox(width) 被夹回 800，网格按
        // 800 排列，与按 [width] 算的期望条数对不上（测的就不是这个宽度）。
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final Map<int, FushiCoverBlockSize> built =
            <int, FushiCoverBlockSize>{};
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: HomeContinueGrid(
                  itemCount: 20,
                  itemBuilder:
                      (BuildContext _, int i, FushiCoverBlockSize size) {
                        built[i] = size;
                        return ColoredBox(
                          key: ValueKey<String>('cell/$i'),
                          color: const Color(0xFF336699),
                        );
                      },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final int visible = homeContinueGridVisibleCount(
          width: width,
          itemCount: 20,
        );
        expect(built.length, visible);
        expect(built[0], FushiCoverBlockSize.hero);
        for (int i = 1; i < visible; i++) {
          expect(built[i], FushiCoverBlockSize.half);
        }
        for (int i = 0; i < visible; i++) {
          final Rect r = tester.getRect(
            find.byKey(ValueKey<String>('cell/$i')),
          );
          expect(r.left, greaterThanOrEqualTo(0), reason: 'cell $i');
          expect(r.right, lessThanOrEqualTo(width + 0.01), reason: 'cell $i');
          expect(r.width, greaterThan(0), reason: 'cell $i');
          expect(
            r.bottom,
            lessThanOrEqualTo(kFushiCoverBlockHeroHeight + 0.01),
            reason: 'cell $i',
          );
        }
        expect(find.byKey(ValueKey<String>('cell/$visible')), findsNothing);
      });
    }
  });

  group('HomeSectionHeader', () {
    testWidgets('「全部 ›」可经焦点 + Enter 触发', (WidgetTester tester) async {
      int opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: HomeSectionHeader(
              title: 'Continue',
              seeAllKey: const ValueKey<String>('see-all'),
              onSeeAll: () => opened++,
            ),
          ),
        ),
      );
      bool focusedSeeAll() {
        final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx == null) return false;
        bool found = false;
        ctx.visitAncestorElements((Element e) {
          if (e.widget.key == const ValueKey<String>('see-all')) found = true;
          return !found;
        });
        return found;
      }

      for (int i = 0; i < 4 && !focusedSeeAll(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(find.byType(FushiTextButton), findsOneWidget);
      expect(focusedSeeAll(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('没有回调时不画「全部」', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Material(child: HomeSectionHeader(title: 'Continue')),
        ),
      );
      expect(find.byType(FushiTextButton), findsNothing);
    });
  });

  group('HomeStatTile（H2 / H5）', () {
    testWidgets('手机 104 高两格并排、桌面 132 高带动作：不溢出', (WidgetTester tester) async {
      final FushiCoverBlockColors colors = FushiCoverBlockColors.fromHue(
        ThemeData(),
        180,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Column(
              children: <Widget>[
                SizedBox(
                  width: 360,
                  child: HomeTileRow(
                    children: <Widget>[
                      HomeStatTile(
                        colors: colors,
                        icon: FushiIcons.barChart,
                        label: 'Reading',
                        value: '0',
                        unit: 'chars',
                        detail: 'Goal 20000 · 0 min',
                        ring: 0,
                        height: kHomeStatTileHeightCompact,
                      ),
                      HomeStatTile(
                        colors: colors,
                        icon: FushiIcons.repeat,
                        label: 'Review',
                        value: '1429',
                        unit: 'due',
                        detail: '7 learning · 28 new',
                        ring: double.nan,
                        height: kHomeStatTileHeightCompact,
                        onTap: () {},
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 480,
                  child: HomeStatTile(
                    colors: colors,
                    icon: FushiIcons.repeat,
                    label: 'Review',
                    value: '1175',
                    unit: 'due',
                    detail: '6 learning · 28 new · Today 0 reviewed',
                    action: FilledButton(
                      onPressed: () {},
                      child: const Text('Review'),
                    ),
                    height: kHomeStatTileHeight,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final Element e in find.byType(HomeStatTile).evaluate()) {
        final HomeStatTile tile = e.widget as HomeStatTile;
        expect(tester.getSize(find.byWidget(tile)).height, tile.height);
      }
    });
  });

  group('H3 头像同步状态', () {
    test('只有首页由头像承载后台任务（不挂右下 FAB）', () {
      for (final HomeTab tab in HomeTab.values) {
        expect(homeBackgroundTasksOnAvatar(tab), tab == HomeTab.home);
      }
    });

    test('空 = idle，在跑 = running，有失败 = failed（失败优先）', () {
      const BackgroundTask running = BackgroundTask(
        id: 'sync-1',
        icon: FushiIcons.sync,
        line: 'Syncing',
      );
      const BackgroundTask failedDone = BackgroundTask(
        id: 'sync-2',
        icon: FushiIcons.sync,
        line: 'Synced',
        errors: <String>['boom'],
        finished: true,
      );
      expect(
        homeAvatarSyncStateOf(const <BackgroundTask>[]),
        HomeAvatarSyncState.idle,
      );
      expect(
        homeAvatarSyncStateOf(const <BackgroundTask>[running]),
        HomeAvatarSyncState.running,
      );
      expect(
        homeAvatarSyncStateOf(const <BackgroundTask>[running, failedDone]),
        HomeAvatarSyncState.failed,
      );
      expect(
        homeAvatarSyncStateOf(const <BackgroundTask>[failedDone]),
        HomeAvatarSyncState.failed,
      );
    });

    test('底部渐隐：从底栏上沿开始淡，到底栏中线全透明', () {
      final LinearGradient g = homeBottomFadeGradient(height: 800, inset: 100);
      expect(g.stops, <double>[0, (800 - 100) / 800, (800 - 50) / 800]);
      expect(g.colors.last.a, 0);
      expect(g.colors.first.a, 1);
    });
  });
}
