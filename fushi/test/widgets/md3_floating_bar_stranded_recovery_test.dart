// BUG-4323（反馈 TyMqz158nj）：MD3 悬浮底栏在查词页收起后回不来，用户离不开查词页。
//
// 查词是胶囊外的 FAB；BUG-3064 让查词页下滑也收起底栏——FAB 当前项时整条胶囊
// 让位，只剩 FAB。恢复原本只有「回滚」与「切 tab」两条路，可查词页上点 FAB 只会
// 清空查询（tab 不变，不触发切 tab 的展开），清空后换成的历史页没有可滚动内容，
// 回滚也无从谈起，底栏就永远收着。
//
// 修复后的两条恢复路径：
// 1. 内容被换掉 / 缩短到滚不动（或新内容停在顶部）：只发 ScrollMetricsNotification，
//    [FushiAppleScrollChrome] 也据此展开；
// 2. 收起态下点「当前项」的 FAB：只展开底栏，不重复触发目的地。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart';
import 'package:material_ui/material_ui.dart';

const List<AdaptiveNavItem> _items = <AdaptiveNavItem>[
  AdaptiveNavItem(icon: Icons.home_outlined, label: 'Home'),
  AdaptiveNavItem(icon: Icons.menu_book_outlined, label: 'Books'),
  AdaptiveNavItem(icon: Icons.search, label: 'Lookup'),
];

const int _lookup = 2;

Finder _hittableIcon(IconData icon) => find.byIcon(icon).hitTestable();

/// 首页外壳的同款接线：内容区 NotificationListener 喂 [FushiAppleScrollChrome]，
/// 底栏随它收起 / 展开，当前 tab 是查词（FAB）。[itemCount] 模拟查词页内容：
/// 长 = 结果可滚，短 = 清空后的历史页（滚不动）。[contentKey] 换掉整个列表
/// （内容替换，新列表从顶部开始）。
class _Shell extends StatelessWidget {
  const _Shell({
    required this.chrome,
    required this.itemCount,
    required this.contentKey,
    required this.taps,
  });

  final FushiAppleScrollChrome chrome;
  final ValueNotifier<int> itemCount;
  final ValueNotifier<int> contentKey;
  final List<int> taps;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: FushiFocusRoot(
        child: Scaffold(
          extendBody: true,
          body: NotificationListener<Notification>(
            onNotification: chrome.handleNotification,
            child: ValueListenableBuilder<int>(
              valueListenable: contentKey,
              builder: (BuildContext context, int key, Widget? _) =>
                  ValueListenableBuilder<int>(
                    valueListenable: itemCount,
                    builder: (BuildContext context, int count, Widget? _) =>
                        ListView.builder(
                          key: ValueKey<int>(key),
                          itemExtent: 60,
                          itemCount: count,
                          itemBuilder: (BuildContext context, int index) =>
                              Text('Row $index'),
                        ),
                  ),
            ),
          ),
          bottomNavigationBar: ListenableBuilder(
            listenable: chrome,
            builder: (BuildContext context, Widget? _) => adaptiveBottomBar(
              context: context,
              currentIndex: _lookup,
              onTap: taps.add,
              items: _items,
              glassMinimized: chrome.minimized,
              onGlassExpand: chrome.expand,
              glassSearchIndex: _lookup,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required FushiAppleScrollChrome chrome,
  required ValueNotifier<int> itemCount,
  required ValueNotifier<int> contentKey,
  required List<int> taps,
}) async {
  tester.view.physicalSize = const Size(412, 892);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _Shell(
      chrome: chrome,
      itemCount: itemCount,
      contentKey: contentKey,
      taps: taps,
    ),
  );
  await tester.pumpAndSettle();
}

/// 用户在列表上往下滚 [distance]（手指上推）。
Future<void> _scrollDown(WidgetTester tester, double distance) async {
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(find.byType(ListView)),
  );
  for (double moved = 0; moved < distance; moved += 20) {
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  late FushiAppleScrollChrome chrome;
  late ValueNotifier<int> itemCount;
  late ValueNotifier<int> contentKey;
  late List<int> taps;

  setUp(() {
    chrome = FushiAppleScrollChrome();
    itemCount = ValueNotifier<int>(80);
    contentKey = ValueNotifier<int>(0);
    taps = <int>[];
  });

  tearDown(() {
    chrome.dispose();
    itemCount.dispose();
    contentKey.dispose();
  });

  Future<void> collapseOnLookup(WidgetTester tester) async {
    await _pumpShell(
      tester,
      chrome: chrome,
      itemCount: itemCount,
      contentKey: contentKey,
      taps: taps,
    );
    expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
    await _scrollDown(tester, 300);
    expect(chrome.minimized, isTrue);
    // 前提：FAB 当前项收起 = 整条胶囊让位，只剩 FAB（BUG-3064）。
    expect(_hittableIcon(Icons.home_outlined), findsNothing);
    expect(_hittableIcon(Icons.menu_book_outlined), findsNothing);
    expect(_hittableIcon(Icons.search), findsOneWidget);
  }

  testWidgets('收起 → 内容缩短到滚不动（清空到历史页）→ 底栏展开', (WidgetTester tester) async {
    await collapseOnLookup(tester);

    itemCount.value = 3;
    await tester.pumpAndSettle();

    expect(chrome.minimized, isFalse);
    expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
    expect(_hittableIcon(Icons.menu_book_outlined), findsOneWidget);
  });

  testWidgets('收起 → 内容整块换成新列表（从顶部开始）→ 底栏展开', (WidgetTester tester) async {
    await collapseOnLookup(tester);

    contentKey.value = 1;
    await tester.pumpAndSettle();

    expect(chrome.minimized, isFalse);
    expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
  });

  testWidgets('收起 → 点当前项 FAB → 只展开底栏，不重复触发目的地', (WidgetTester tester) async {
    await collapseOnLookup(tester);

    await tester.tap(_hittableIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(chrome.minimized, isFalse);
    expect(taps, isEmpty);
    expect(_hittableIcon(Icons.home_outlined), findsOneWidget);
    expect(_hittableIcon(Icons.menu_book_outlined), findsOneWidget);

    // 展开后再点 FAB 照旧走目的地（查词导航入口：清空查询 / 聚焦搜索框）。
    await tester.tap(_hittableIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(taps, <int>[_lookup]);
  });

  testWidgets('收起时列表仍可滚、仍停在中间：尺寸通知不误展开', (WidgetTester tester) async {
    await collapseOnLookup(tester);

    // 列表变长（懒加载追加）：内容仍可滚、位置不在顶部，保持收起。
    itemCount.value = 120;
    await tester.pumpAndSettle();

    expect(chrome.minimized, isTrue);
    expect(_hittableIcon(Icons.home_outlined), findsNothing);
  });
}
