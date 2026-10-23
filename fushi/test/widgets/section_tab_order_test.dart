import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';
import 'package:fushi/src/utils/components/section_tab_order.dart';

// 反馈 ndQ5eXLcqp：库页顶部页签可自定义顺序。组件层统一实现：存的是页签 id，
// 新增 / 未知页签追加在末尾；长按页签栏弹排序面板，调整即时重排、即时落库；
// MD3 与 Apple 两套呈现都按同一顺序画。
class _MemoryStore implements SectionTabOrderStore {
  _MemoryStore(this.ids);

  List<String> ids;
  final List<List<String>> writes = <List<String>>[];

  @override
  List<String> read(String orderKey) => ids;

  @override
  Future<void> write(String orderKey, List<String> next) async {
    writes.add(next);
    ids = next;
  }
}

const List<LibrarySectionTab<String>> _tabs = <LibrarySectionTab<String>>[
  LibrarySectionTab<String>(value: 'a', label: 'Alpha'),
  LibrarySectionTab<String>(value: 'b', label: 'Bravo'),
  LibrarySectionTab<String>(value: 'c', label: 'Charlie'),
];

void main() {
  group('orderSectionTabs', () {
    List<String> labels(List<LibrarySectionTab<String>> tabs) => <String>[
      for (final LibrarySectionTab<String> tab in tabs) tab.label,
    ];

    test('stored ids first, unknown tabs appended, missing ids ignored', () {
      expect(
        labels(orderSectionTabs(_tabs, const <String>['c', 'gone', 'a'])),
        <String>['Charlie', 'Alpha', 'Bravo'],
      );
      expect(labels(orderSectionTabs(_tabs, const <String>[])), <String>[
        'Alpha',
        'Bravo',
        'Charlie',
      ]);
      expect(
        labels(orderSectionTabs(_tabs, const <String>['b', 'b'])),
        <String>['Bravo', 'Alpha', 'Charlie'],
      );
    });

    test('orderId overrides the value as the identity', () {
      const LibrarySectionTab<String> grouped = LibrarySectionTab<String>(
        value: 'whatever-is-active',
        label: 'Group',
        orderId: 'group',
      );
      expect(sectionTabOrderId(grouped), 'group');
      expect(
        labels(
          orderSectionTabs(
            <LibrarySectionTab<String>>[..._tabs, grouped],
            const <String>['group'],
          ),
        ).first,
        'Group',
      );
    });

    test('parse drops blanks', () {
      expect(parseSectionTabOrder(' a, ,b '), <String>['a', 'b']);
      expect(parseSectionTabOrder(null), isEmpty);
    });
  });

  Future<void> pump(
    WidgetTester tester,
    _MemoryStore store, {
    required bool glass,
  }) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.off,
          glassDesign: glass,
        ),
        home: FushiGlassScope(
          child: SectionTabOrderScope(
            store: store,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: LibrarySectionTabs<String>(
                  tabs: _tabs,
                  selected: 'a',
                  onChanged: (_) {},
                  focusIdPrefix: 'test-tabs',
                  orderKey: 'test',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> shownOrder(WidgetTester tester) {
    final List<String> labels = <String>['Alpha', 'Bravo', 'Charlie'];
    labels.sort(
      (String a, String b) => tester
          .getTopLeft(find.text(a).last)
          .dx
          .compareTo(tester.getTopLeft(find.text(b).last).dx),
    );
    return labels;
  }

  for (final bool glass in <bool>[false, true]) {
    testWidgets('stored order is applied (${glass ? 'Apple' : 'MD3'})', (
      WidgetTester tester,
    ) async {
      await pump(tester, _MemoryStore(<String>['c', 'a']), glass: glass);
      expect(shownOrder(tester), <String>['Charlie', 'Alpha', 'Bravo']);
    });
  }

  testWidgets('long press opens the sheet; moving a tab reorders and saves', (
    WidgetTester tester,
  ) async {
    final _MemoryStore store = _MemoryStore(<String>[]);
    await pump(tester, store, glass: false);
    expect(shownOrder(tester), <String>['Alpha', 'Bravo', 'Charlie']);

    await tester.longPress(find.text('Bravo'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('section-tab-order-row-c')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('section-tab-order-up-c')),
    );
    await tester.pumpAndSettle();
    expect(store.writes.last, <String>['a', 'c', 'b']);

    await tester.tap(
      find.byKey(const ValueKey<String>('section-tab-order-done')),
    );
    await tester.pumpAndSettle();
    expect(shownOrder(tester), <String>['Alpha', 'Charlie', 'Bravo']);

    // 恢复默认：清空存储，回到宿主顺序。
    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('section-tab-order-reset')),
    );
    await tester.pumpAndSettle();
    expect(store.writes.last, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey<String>('section-tab-order-done')),
    );
    await tester.pumpAndSettle();
    expect(shownOrder(tester), <String>['Alpha', 'Bravo', 'Charlie']);
  });
}
