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
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';
import '../helpers/test_platform_services.dart';

/// 「外观 → 底栏中央展开」的**生效**测试（settings_schema_coverage 的
/// kCoveredElsewhere 指到这里）。
///
/// 走设置页那一行真正的 onChanged 写偏好，再把 AppModel 读出的值按首页外壳的
/// 同一接线（`centerLauncher: appModel.navBarCenterLauncher`，下方源码守卫钉住）
/// 喂给生产底栏 [adaptiveBottomBar]，断言屏幕上看得见的结果：开时 9 个入口只
/// 剩首尾各两项 + 中央「+」，关时回到平铺（中间的入口重新出现在栏上）。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  /// 设置行的 onChanged 是 `unawaited(写偏好.then(refresh))`：等 refresh 信号。
  Completer<void>? written;

  final List<String> labels = <String>[for (int i = 0; i < 9; i++) 'T$i'];

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('nav_launcher_setting_effect_');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  SettingsSwitchItem launcherRow() => buildAppearanceDestination().sections
      .expand((SettingsSection s) => s.items)
      .whereType<SettingsSwitchItem>()
      .singleWhere(
        (SettingsSwitchItem item) =>
            item.id == 'appearance.nav_bar_center_launcher',
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
                      centerLauncher: appModel.navBarCenterLauncher,
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

  Future<void> toggle(WidgetTester tester, bool value) async {
    final Completer<void> done = written = Completer<void>();
    await launcherRow().onChanged(settingsContext, value);
    for (int i = 0; i < 20 && !done.isCompleted; i++) {
      await tester.pump();
    }
    expect(done.isCompleted, isTrue, reason: '设置行的写偏好链必须走完');
    written = null;
  }

  testWidgets('center launcher row switches the bottom bar layout', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);

    // 默认关：宽 1200 下 9 个入口全部平铺，没有「+」。
    await pumpShell(tester);
    expect(launcherRow().value(settingsContext), isFalse);
    expect(onBar('T4'), isTrue);
    expect(onBar(t.home_nav_more), isFalse);

    // 打开：只剩首尾各两项 + 「+」。
    await toggle(tester, true);
    expect(appModel.navBarCenterLauncher, isTrue);
    await pumpShell(tester);
    expect(onBar('T0') && onBar('T1') && onBar('T7') && onBar('T8'), isTrue);
    expect(onBar('T4'), isFalse);
    expect(onBar(t.home_nav_more), isTrue);

    // 再关掉：回到平铺。
    await toggle(tester, false);
    expect(appModel.navBarCenterLauncher, isFalse);
    await pumpShell(tester);
    expect(onBar('T4'), isTrue);
    expect(onBar(t.home_nav_more), isFalse);
  });

  test('home shell feeds the bottom bar from navBarCenterLauncher', () {
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(
      compactCode(methodBody(home, 'Widget _buildMobileLayout(')),
      contains('centerLauncher:appModel.navBarCenterLauncher'),
    );
  });
}
