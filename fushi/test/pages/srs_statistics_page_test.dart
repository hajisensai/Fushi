// 统计中心「复习」分区：窄屏（手机竖屏）/ 横屏 / 宽屏各 pump 一次，断言每个区块都在、
// 不溢出，切换范围 / 视图不抛；空库给空数据态；复习模块关着时统计中心没有这个 tab。
//
// 内存库 + 确定性假排程内核 + 可拨的可信时钟（复习历史按天铺开）。数据库读写一律放
// tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs_statistics_page.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/pages/implementations/srs_stat_charts.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import '../srs/srs_test_support.dart';

const List<String> kSectionKeys = <String>[
  'srs-stats-today',
  'srs-stats-today-detail',
  'srs-stats-future',
  'srs-stats-calendar',
  'srs-stats-reviews',
  'srs-stats-card-counts',
  'srs-stats-retention',
  'srs-stats-memory',
  'srs-stats-added',
  'srs-stats-sources',
];

/// 一个带 45 天复习历史的库：30 张卡，按天轮流复习，评分轮换；一张暂停。
Future<SrsDbStore> _seededStore(WidgetTester tester, SrsTestClock clock) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(clock: clock),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  await tester.runAsync(() async {
    final List<String> cards = <String>[];
    for (int i = 0; i < 30; i++) {
      final String note = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '単語$i',
        },
        source: i.isEven
            ? SrsSourceRef.book(
                bookKey: 'bk',
                sectionIndex: 0,
                charStart: i,
                title: '無職転生',
              )
            : null,
      );
      cards.add((await store.cardsOfNote(note)).single.id);
    }
    const List<int> ratings = <int>[3, 3, 4, 1, 3, 2];
    for (int d = 0; d < 45; d++) {
      for (int i = 0; i < 24; i++) {
        if ((i + d) % 4 != 0) continue;
        await store.answer(
          cards[i],
          ratings[(i * 7 + d) % ratings.length],
          durationMs: 4000 + i * 300,
        );
        clock.advance(const Duration(minutes: 3));
      }
      clock.advance(const Duration(hours: 23));
    }
    await store.setSuspended(cards[29], true);
  });
  return store;
}

Future<void> _settle(WidgetTester tester, {int rounds = 16}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required SrsDbStore store,
  required Size size,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: brightness,
            ),
            textTheme: brightness == Brightness.dark
                ? Typography.material2021().white
                : Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: const Scaffold(body: SrsStatisticsTab()),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('复习模块关着时统计中心没有「复习」tab', () {
    expect(
      statsCenterVisibleTabs(srsEnabled: false),
      isNot(contains(StatsCenterTab.srs)),
    );
    expect(statsCenterVisibleTabs(srsEnabled: true).last, StatsCenterTab.srs);
    expect(statsCenterVisibleTabs(srsEnabled: false), hasLength(4));
  });

  test('多列排布：按顺序放进最矮的一列，单列保持原顺序', () {
    expect(srsStatsColumnSlots(<double>[1, 1, 1], 1), <List<int>>[
      <int>[0, 1, 2],
    ]);
    expect(srsStatsColumnSlots(<double>[3, 1, 1, 1], 2), <List<int>>[
      <int>[0],
      <int>[1, 2, 3],
    ]);
    expect(srsStatsColumnSlots(<double>[2, 2, 2, 2, 2], 3), <List<int>>[
      <int>[0, 3],
      <int>[1, 4],
      <int>[2],
    ]);
  });

  for (final (String name, Size size, int columns) in <(String, Size, int)>[
    ('手机竖屏 390×844', const Size(390, 844), 1),
    ('手机横屏 844×390', const Size(844, 390), 2),
    ('桌面 1366×900', const Size(1366, 900), 3),
  ]) {
    testWidgets('$name：全部区块在、列数按宽度、不溢出', (WidgetTester tester) async {
      final SrsTestClock clock = SrsTestClock(
        DateTime.utc(2026, 7, 1, 1).millisecondsSinceEpoch,
      );
      final SrsDbStore store = await _seededStore(tester, clock);
      await _pump(tester, store: store, size: size);
      expect(tester.takeException(), isNull);
      for (final String key in kSectionKeys) {
        expect(
          find.byKey(ValueKey<String>(key), skipOffstage: false),
          findsOneWidget,
          reason: key,
        );
      }
      expect(
        find.byKey(
          ValueKey<String>('srs-stats-columns-$columns'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('stat-dashboard-empty')),
        findsNothing,
      );

      // 切范围 / 视图：重算全部区块，不抛、不溢出。
      for (final String label in <String>['1 year', 'All time', '3 months']) {
        await tester.tap(find.text(label).first);
        await _settle(tester, rounds: 3);
        expect(tester.takeException(), isNull, reason: label);
      }
      final Finder timeToggle = find.descendant(
        of: find.byKey(
          const ValueKey<String>('srs-stats-reviews-view'),
          skipOffstage: false,
        ),
        matching: find.text('Time', skipOffstage: false),
      );
      await tester.ensureVisible(timeToggle);
      await tester.pump();
      await tester.tap(timeToggle);
      await _settle(tester, rounds: 3);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }

  testWidgets('深色主题 + 宽屏：配色跟随主题，不抛', (WidgetTester tester) async {
    final SrsTestClock clock = SrsTestClock(
      DateTime.utc(2026, 7, 1, 1).millisecondsSinceEpoch,
    );
    final SrsDbStore store = await _seededStore(tester, clock);
    await _pump(
      tester,
      store: store,
      size: const Size(1100, 900),
      brightness: Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('srs-stats-future')), findsOne);
    await _unmount(tester);
  });

  testWidgets('点按柱子出数值气泡、点环形图图例选中一段', (WidgetTester tester) async {
    final SrsTestClock clock = SrsTestClock(
      DateTime.utc(2026, 7, 1, 1).millisecondsSinceEpoch,
    );
    final SrsDbStore store = await _seededStore(tester, clock);
    await _pump(tester, store: store, size: const Size(1366, 900));
    final Finder reviews = find.byKey(
      const ValueKey<String>('srs-stats-reviews'),
    );
    final Finder chart = find.descendant(
      of: reviews,
      matching: find.byType(SrsBarChart),
    );
    await tester.ensureVisible(chart);
    await tester.pump();
    final Rect r = tester.getRect(chart);
    await tester.tapAt(Offset(r.right - 4, r.center.dy));
    await tester.pump();
    // 选中最后一根柱（今天）：语义标签是气泡内容（标题 + 各系列 + 合计）。
    expect(find.bySemanticsLabel(RegExp('Total')), findsWidgets);
    final Finder legend = find.byKey(
      const ValueKey<String>('srs-donut-legend-4'),
    );
    await tester.ensureVisible(legend);
    await tester.tap(legend);
    await tester.pump();
    expect(find.textContaining('Mature ·'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('空库给空数据态，筛选控件照常在', (WidgetTester tester) async {
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      () => openSrsTestStore(),
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    await _pump(tester, store: store, size: const Size(390, 844));
    expect(
      find.byKey(const ValueKey<String>('stat-dashboard-empty')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('srs-stats-range')), findsOne);
    expect(
      find.byKey(const ValueKey<String>('srs-stats-future')),
      findsNothing,
    );
    await _unmount(tester);
  });
}
