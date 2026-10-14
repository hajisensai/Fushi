import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';
import '../helpers/test_platform_services.dart';

/// 「外观 → 底栏样式」的**生效**测试（settings_schema_coverage 的
/// kCoveredElsewhere 指到这里）。
///
/// 走设置页那一行真正的 onChanged 写偏好，再把 AppModel 读出的值按首页外壳的
/// 同一接线（`barStyle: appModel.navBarStyle`，下方源码守卫钉住）喂给生产底栏
/// [adaptiveBottomBar]，断言屏幕上看得见的结果：
/// - 平铺（默认）：1200 宽下 9 个入口全部平铺，没有「+」；
/// - 中央展开：只剩首尾各两项 + 「+」；
/// - 分页滑动：一页 5 个（T0–T4），后面的不在栏上，没有「+」；
/// - 中央展开 + 翻页：一页两侧 4 个（T0–T3）+ 「+」。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  /// 设置行的 onChanged 是「写偏好.then(refresh)」：等 refresh 信号。
  Completer<void>? written;

  final List<String> labels = <String>[for (int i = 0; i < 9; i++) 'T$i'];

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('nav_style_setting_effect_');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  SettingsSegmentedItem<AdaptiveNavBarStyle> styleRow() =>
      buildAppearanceDestination().sections
          .expand((SettingsSection s) => s.items)
          .whereType<SettingsSegmentedItem<AdaptiveNavBarStyle>>()
          .singleWhere(
            (SettingsSegmentedItem<AdaptiveNavBarStyle> item) =>
                item.id == 'appearance.nav_bar_style',
          );

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: FushiFocusRoot(
            child: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                settingsContext = SettingsContext(
                  context: context,
                  appModel: appModel,
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () => written?.complete(),
                );
                return Scaffold(
                  body: const SizedBox.expand(),
                  bottomNavigationBar: Builder(
                    builder: (BuildContext context) => adaptiveBottomBar(
                      context: context,
                      currentIndex: 0,
                      onTap: (_) {},
                      items: <AdaptiveNavItem>[
                        for (final String label in labels)
                          AdaptiveNavItem(
                            icon: Icons.circle_outlined,
                            label: label,
                          ),
                      ],
                      barStyle: appModel.navBarStyle,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool onBar(String label) =>
      find.text(label).hitTestable().evaluate().isNotEmpty;

  List<String> visible() => <String>[
    for (final String l in labels)
      if (onBar(l)) l,
  ];

  Future<void> choose(WidgetTester tester, AdaptiveNavBarStyle value) async {
    final Completer<void> done = written = Completer<void>();
    unawaited(
      Future<void>.value(styleRow().dispatchChange(settingsContext, value)),
    );
    for (int i = 0; i < 20 && !done.isCompleted; i++) {
      await tester.pump();
    }
    expect(done.isCompleted, isTrue, reason: '设置行的写偏好链必须走完');
    written = null;
    expect(appModel.navBarStyle, value);
    await pumpShell(tester);
  }

  testWidgets('bottom bar style row switches among the four layouts', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);

    await pumpShell(tester);
    expect(styleRow().selected(settingsContext), AdaptiveNavBarStyle.flat);
    expect(visible(), labels, reason: '默认平铺：1200 宽全部平铺');
    expect(onBar(t.home_nav_more), isFalse);

    await choose(tester, AdaptiveNavBarStyle.launcher);
    expect(visible(), <String>['T0', 'T1', 'T7', 'T8']);
    expect(onBar(t.home_nav_more), isTrue);

    await choose(tester, AdaptiveNavBarStyle.pager);
    expect(visible(), <String>['T0', 'T1', 'T2', 'T3', 'T4']);
    expect(onBar(t.home_nav_more), isFalse);

    await choose(tester, AdaptiveNavBarStyle.launcherPager);
    expect(visible(), <String>['T0', 'T1', 'T2', 'T3']);
    expect(onBar(t.home_nav_more), isTrue);

    await choose(tester, AdaptiveNavBarStyle.flat);
    expect(visible(), labels);
  });

  test('home shell feeds the bottom bar from navBarStyle', () {
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    final String body = compactCode(
      methodBody(home, 'Widget _buildMobileLayout('),
    );
    expect(body, contains('barStyle:appModel.navBarStyle'));
    // 横滑切模块的序列也跟着底栏形态带上查词。
    expect(
      compactCode(home),
      contains('lookupInBar:appModel.navBarStyle.lookupInBar'),
    );
  });
}
