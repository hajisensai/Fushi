import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/reader/reader_chrome_floating.dart';
import 'package:fushi/src/reader/reader_status_footer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// 「阅读 → 工具栏样式」（悬浮 / 贴边）的**生效**测试（settings_schema_coverage
/// 的 kCoveredElsewhere 指到这里）。
///
/// 阅读器页本身要活 WebView，widget 层起不来；所以分三段咬住整条链：
/// 1. 设置行真正的 onChanged 写偏好，AppModel 读回；
/// 2. 偏好 → 「是否悬浮」只经 [readerToolbarsFloating] 换算，阅读器页的
///    `_floatingToolbars` 也只经它（源码守卫）；
/// 3. 页面把这个结论喂给生产组件 [ReaderStatusFooter]——渲染出来的形态真的不同：
///    悬浮是一枚浮在正文上的胶囊（整条带透明），贴边是一条整宽实体底栏。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('reader_toolbar_style_effect_');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Iterable<SettingsItem> allItems(SettingsDestination destination) sync* {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        yield item;
        if (item is SettingsNavigationItem && item.child != null) {
          yield* allItems(item.child!());
        }
      }
    }
  }

  SettingsSegmentedItem<String> styleRow() =>
      allItems(
        buildReadingDestination(),
      ).whereType<SettingsSegmentedItem<String>>().singleWhere(
        (SettingsSegmentedItem<String> item) =>
            item.id == 'reading_controls.toolbar_style',
      );

  /// 设置上下文 + 一条按 AppModel 当前样式渲染的状态行（与页面同一换算）。
  Future<void> pumpFooter(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              settingsContext = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 600,
                    child: ReaderStatusFooter(
                      sessionTotals: () =>
                          (durationMs: 180000, chars: 120, active: true),
                      currentChars: 500,
                      totalChars: 1000,
                      showTimer: true,
                      showProgress: true,
                      textColor: Colors.white,
                      backgroundColor: Colors.black,
                      floating: readerToolbarsFloating(
                        appModel.readerToolbarStyle,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final Finder pill = find.byKey(
    const ValueKey<String>('fushi_status_footer_pill'),
  );

  Color bandColor(WidgetTester tester) => tester
      .widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(ReaderStatusFooter),
              matching: find.byType(ColoredBox),
            )
            .first,
      )
      .color;

  testWidgets('toolbar style row switches the reader chrome form', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);

    // 默认悬浮：读数是一枚胶囊，整条带透明，带高多出离窗底的外边距。
    await pumpFooter(tester);
    final SettingsSegmentedItem<String> row = styleRow();
    expect(row.selected(settingsContext), 'floating');
    expect(pill, findsOneWidget);
    expect(bandColor(tester), Colors.transparent);
    final double floatingBand = tester
        .getSize(find.byType(ReaderStatusFooter))
        .height;
    expect(floatingBand, readerStatusFooterPaintedHeight(floating: true));
    expect(
      tester.getSize(pill).width,
      lessThan(600),
      reason: '悬浮读数只是一枚胶囊，不铺满整宽',
    );

    // 选贴边：设置行写偏好 → 状态行变成整宽实体条（无胶囊、铺底色、无外边距）。
    await tester.runAsync(() async => row.onChanged(settingsContext, 'docked'));
    expect(appModel.readerToolbarStyle, 'docked');
    await pumpFooter(tester);
    expect(row.selected(settingsContext), 'docked');
    expect(pill, findsNothing);
    expect(bandColor(tester), Colors.black);
    expect(
      tester.getSize(find.byType(ReaderStatusFooter)).height,
      readerStatusFooterPaintedHeight(floating: false),
    );
    expect(
      tester.getSize(find.byType(ReaderStatusFooter)).height,
      lessThan(floatingBand),
    );

    // 选回悬浮：胶囊回来。
    await tester.runAsync(
      () async => row.onChanged(settingsContext, 'floating'),
    );
    await pumpFooter(tester);
    expect(pill, findsOneWidget);
  });

  test('only an explicit docked style is docked', () {
    expect(readerToolbarsFloating('floating'), isTrue);
    expect(readerToolbarsFloating('docked'), isFalse);
    expect(readerToolbarsFloating(''), isTrue, reason: '未知值回落默认悬浮');
  });

  test('reader page derives its chrome form from readerToolbarsFloating', () {
    final String page = readReaderPageSource();
    expect(
      page,
      contains(
        'bool get _floatingToolbars =>\n'
        '      readerToolbarsFloating(appModel.readerToolbarStyle);',
      ),
    );
    // 结论真的被用在状态行、顶栏与底栏三处形态分叉上。
    expect(page, contains('floating: _floatingToolbars,'));
    expect(
      page,
      contains('if (_floatingToolbars) return _buildFloatingHeader();'),
    );
    expect(
      page,
      contains('if (_floatingToolbars) return _buildFloatingBottomChrome();'),
    );
  });
}
