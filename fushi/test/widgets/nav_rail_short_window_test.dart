import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4971：窗口矮时（用户截图约 830×717）镂空脊侧栏排不开。
///
/// - 所有目的地都要可达（排不下就紧凑间距 + 滚动，不裁条目），没有 overflow；
/// - 当前项的缺口在任何位置（含被挤到最底部）都完整：上下沿包住指示器槽并各
///   多出 bleed，且缺口连同内凹圆角都落在内容区起始边的直线段上，不伸进舞台
///   左上 / 左下大圆角（旧实现缺口贴底时内凹圆角伸进舞台左下圆角，被舞台补角
///   的侧栏色盖出缺口）。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.photo_library_outlined, label: '漫画'),
    AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
    AdaptiveNavItem(icon: Icons.sports_esports_outlined, label: '游戏'),
    AdaptiveNavItem(icon: Icons.explore_outlined, label: '发现'),
    AdaptiveNavItem(icon: Icons.search, label: '查词'),
    AdaptiveNavItem(icon: Icons.sync, label: '同步'),
    AdaptiveNavItem(icon: Icons.music_note_outlined, label: '音乐'),
    AdaptiveNavItem(icon: Icons.public, label: '浏览器'),
    AdaptiveNavItem(icon: Icons.tune, label: '设置'),
  ];
  const Key stageKey = ValueKey<String>('stage');
  final Finder surface = find.byWidgetPredicate(
    (Widget w) => w.runtimeType.toString() == '_RailNotchSurface',
  );
  final Finder railScroll = find.descendant(
    of: surface,
    matching: find.byType(SingleChildScrollView),
  );

  Widget harness({required bool extended, required int selected}) {
    return MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        extensions: const <ThemeExtension<dynamic>>[
          FushiShellTheme(railStyle: ShellRailStyle.notch),
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: false),
        ],
      ),
      home: Scaffold(
        body: NavRailContentSync(
          child: Row(
            children: <Widget>[
              Builder(
                builder: (BuildContext context) => adaptiveNavRail(
                  context: context,
                  currentIndex: selected,
                  onTap: (_) {},
                  items: items,
                  extended: extended,
                  // 品牌位与真外壳同尺寸（头像 64）。
                  leading: const SizedBox.square(dimension: 64),
                  onToggleExtended: () {},
                ),
              ),
              const Expanded(
                child: NavRailStage(child: SizedBox.expand(key: stageKey)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 当前项缺口的全局上下沿。
  ({double top, double bottom}) notchOf(WidgetTester tester) {
    final ({double top, double bottom})? local = debugNavRailNotchExtent(
      tester.element(surface),
    );
    expect(local, isNotNull, reason: '当前项应有缺口');
    final double dy = tester.getTopLeft(surface).dy;
    return (top: local!.top + dy, bottom: local.bottom + dy);
  }

  for (final bool extended in <bool>[false, true]) {
    for (final double height in <double>[717, 600, 480, 400]) {
      final String label = '${extended ? '展开' : '收起'} 830×${height.toInt()}';

      testWidgets('$label：全部目的地可达、无 overflow，选中末项缺口完整', (
        WidgetTester tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(830, height));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        // 从首项切到末项（选中变化才触发自动滚入，与用户点选同一路径）。
        await tester.pumpWidget(harness(extended: extended, selected: 0));
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          harness(extended: extended, selected: items.length - 1),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final Rect stage = tester.getRect(find.byKey(stageKey));
        final double slot = extended
            ? debugNavRailRowHeight(dense: true)
            : debugNavRailCollapsedShapeSize;

        void expectNotchIntact(Rect glyph) {
          final ({double top, double bottom}) notch = notchOf(tester);
          expect(notch.top, lessThanOrEqualTo(glyph.top));
          expect(notch.bottom, greaterThanOrEqualTo(glyph.bottom));
          expect(
            notch.bottom - notch.top,
            greaterThanOrEqualTo(slot + 2 * debugNavRailNotchBleed - 0.5),
            reason: '缺口被截短了',
          );
          expect(
            notch.bottom + debugNavRailNotchFillet,
            lessThanOrEqualTo(
              stage.bottom - debugNavRailStageCornerExtent + 0.5,
            ),
            reason: '缺口的内凹圆角伸进了舞台左下圆角',
          );
          expect(
            notch.top - debugNavRailNotchFillet,
            greaterThanOrEqualTo(
              stage.top + debugNavRailStageCornerExtent - 0.5,
            ),
            reason: '缺口的内凹圆角伸进了舞台左上圆角',
          );
        }

        // 选中末项：自动滚进来，缺口完整。
        final Rect viewport = tester.getRect(railScroll);
        final Rect last = tester.getRect(find.byIcon(items.last.icon));
        expect(viewport.top, lessThanOrEqualTo(last.top + 0.5));
        expect(viewport.bottom, greaterThanOrEqualTo(last.bottom - 0.5));
        expectNotchIntact(last);

        // 每一项都能滚进可视区（不裁条目）。
        for (final AdaptiveNavItem item in items) {
          final Finder icon = find.byIcon(item.icon);
          expect(icon, findsOneWidget, reason: '${item.label} 被裁掉了');
          await tester.ensureVisible(icon);
          await tester.pumpAndSettle();
          final Rect r = tester.getRect(icon);
          expect(r.top, greaterThanOrEqualTo(viewport.top - 0.5));
          expect(r.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('挂载时当前项就是末项：直接滚进可视区，缺口在', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(830, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      harness(extended: false, selected: items.length - 1),
    );
    await tester.pumpAndSettle();
    final Rect viewport = tester.getRect(railScroll);
    final Rect last = tester.getRect(find.byIcon(items.last.icon));
    expect(viewport.top, lessThanOrEqualTo(last.top + 0.5));
    expect(viewport.bottom, greaterThanOrEqualTo(last.bottom - 0.5));
    final ({double top, double bottom}) notch = notchOf(tester);
    expect(notch.top, lessThanOrEqualTo(last.top));
    expect(notch.bottom, greaterThanOrEqualTo(last.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('矮窗口改用紧凑间距，放得下时保持原间距', (WidgetTester tester) async {
    double pitchAt(double height) {
      final Rect a = tester.getRect(find.byIcon(items[0].icon));
      final Rect b = tester.getRect(find.byIcon(items[1].icon));
      return b.center.dy - a.center.dy;
    }

    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(830, 1400));
    await tester.pumpWidget(harness(extended: false, selected: 0));
    await tester.pumpAndSettle();
    final double roomy = pitchAt(1400);

    await tester.binding.setSurfaceSize(const Size(830, 717));
    await tester.pumpAndSettle();
    final double tight = pitchAt(717);
    expect(tight, lessThan(roomy));
    // 紧凑后命中区仍不小于 48dp。
    expect(tight, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}
