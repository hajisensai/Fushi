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
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_mode_strip_bar.dart';
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
/// - 相机模式条（出厂默认，2026-10-23 用户拍板）：栏上画的是模式条（纯图标，
///   没有文字标签），没有「更多」；分页滑动 / 圆柱滚筒两项 2026-10-25 删除，
///   设置里不再出现；
/// - 平铺：1200 宽下 9 个入口全部平铺，没有「+」。
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

  testWidgets('bottom bar style row switches between flat and mode strip', (
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
    // 从没写过偏好 = 出厂默认相机模式条（老用户升级上来同样如此）。
    expect(styleRow().selected(settingsContext), AdaptiveNavBarStyle.modeStrip);
    expect(styleRow().defaultValue, AdaptiveNavBarStyle.modeStrip);
    // 分页滑动 / 圆柱滚筒已删，设置里只剩三项。
    expect(
      <AdaptiveNavBarStyle>[
        for (final SettingsSegmentOption<AdaptiveNavBarStyle> option
            in styleRow().options)
          option.value,
      ],
      <AdaptiveNavBarStyle>[
        AdaptiveNavBarStyle.flat,
        AdaptiveNavBarStyle.dial,
        AdaptiveNavBarStyle.modeStrip,
      ],
    );
    expect(find.byType(NavModeStripBar), findsOneWidget);
    expect(onBar(t.home_nav_more), isFalse);

    await choose(tester, AdaptiveNavBarStyle.flat);
    expect(visible(), labels, reason: '平铺：1200 宽全部平铺');
    expect(onBar(t.home_nav_more), isFalse);
    expect(find.byType(NavModeStripBar), findsNothing);

    // 显式选过平铺的落库了，重新载入偏好后仍是平铺，不被新默认覆盖。
    await tester.runAsync(() async {
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.navBarStyle, AdaptiveNavBarStyle.flat);
    });

    await choose(tester, AdaptiveNavBarStyle.modeStrip);
    expect(find.byType(NavModeStripBar), findsOneWidget);
  });

  test('没写过 / 未知值回落出厂默认相机模式条；显式值原样读回', () {
    expect(AdaptiveNavBarStyle.defaultStyle, AdaptiveNavBarStyle.modeStrip);
    expect(AdaptiveNavBarStyle.fromPref(''), AdaptiveNavBarStyle.modeStrip);
    expect(
      AdaptiveNavBarStyle.fromPref('launcher'),
      AdaptiveNavBarStyle.modeStrip,
    );
    expect(
      AdaptiveNavBarStyle.fromPref('mode_strip'),
      AdaptiveNavBarStyle.modeStrip,
    );
    expect(AdaptiveNavBarStyle.fromPref('flat'), AdaptiveNavBarStyle.flat);
    // 已删样式落过库的值回落出厂默认。
    expect(
      AdaptiveNavBarStyle.fromPref('pager'),
      AdaptiveNavBarStyle.modeStrip,
    );
    expect(AdaptiveNavBarStyle.fromPref('drum'), AdaptiveNavBarStyle.modeStrip);
  });

  test('home shell feeds the bottom bar from navBarStyle', () {
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    final String body = compactCode(
      methodBody(home, 'Widget _buildMobileLayout('),
    );
    expect(body, contains('barStyle:appModel.navBarStyle'));
  });
}
