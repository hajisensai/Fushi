import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// 「外观 → 显示底栏标签」的**生效**测试（settings_schema_coverage 的
/// kCoveredElsewhere 指到这里）。
///
/// 走设置页那一行真正的 onChanged 写偏好，再把 AppModel 读出的值按首页外壳的
/// 同一接线（`showLabels: appModel.navBarLabelsVisible`，下方源码守卫钉住）喂给
/// 生产底栏 [adaptiveBottomBar]，断言屏幕上看得见的结果：开时每个入口下方画出
/// 标签文字，关时标签不再画出、只留 tooltip 补全名，底栏也随之变矮。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  /// 这一行的 onChanged 是 `unawaited(写偏好.then(refresh))`：写完才调
  /// [SettingsContext.refresh]。测试等这个信号，而不是猜一个延迟。写库链挂在
  /// 测试的 fake zone 上（真实时间里不推进），所以靠逐帧 pump 冲刷它。
  Completer<void>? written;

  const List<String> labels = <String>['Books', 'Video', 'Lookup'];

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('nav_labels_setting_effect_');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  SettingsSwitchItem labelsRow() => buildAppearanceDestination().sections
      .expand((SettingsSection s) => s.items)
      .whereType<SettingsSwitchItem>()
      .singleWhere(
        (SettingsSwitchItem item) => item.id == 'appearance.nav_bar_labels',
      );

  /// 一棵树里同时有设置上下文（驱动设置行）与按 AppModel 当前值渲染的底栏。
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 800);
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
                      showLabels: appModel.navBarLabelsVisible,
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

  // 纯图标格的 tooltip 不进语义（名称由外层 Semantics.label 报），按 Tooltip
  // 本身的 message 找：flutter_test 的 byTooltip 只认 SDK 内置 material 的
  // Tooltip 类型，认不出 material_ui 的 Tooltip。
  Finder tooltipOf(String label) =>
      find.byWidgetPredicate((Widget w) => w is Tooltip && w.message == label);

  int paintedLabels() => <String>[
    for (final String label in labels)
      if (find.text(label).hitTestable().evaluate().isNotEmpty) label,
  ].length;

  Future<void> toggle(WidgetTester tester, bool value) async {
    final Completer<void> done = written = Completer<void>();
    await labelsRow().onChanged(settingsContext, value);
    for (int i = 0; i < 20 && !done.isCompleted; i++) {
      await tester.pump();
    }
    expect(done.isCompleted, isTrue, reason: '设置行的写偏好链必须走完');
    written = null;
  }

  testWidgets('labels row shows / hides the bottom bar labels', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);

    // 默认关（纯图标出厂形态）：底栏不画标签，只剩 tooltip 补全名。
    await pumpShell(tester);
    final SettingsSwitchItem row = labelsRow();
    expect(row.value(settingsContext), isFalse);
    expect(paintedLabels(), 0, reason: '默认纯图标：底栏一个标签都不该画出来');
    for (final String label in labels) {
      expect(
        tooltipOf(label),
        findsWidgets,
        reason: '纯图标形态要用 tooltip 补出 $label 的全名',
      );
    }
    final double offNavTop = tester
        .getTopLeft(tooltipOf(labels.first).first)
        .dy;

    // 打开：设置行写偏好 → 每个入口都画出标签。
    await toggle(tester, true);
    expect(appModel.navBarLabelsVisible, isTrue);
    await pumpShell(tester);
    expect(paintedLabels(), labels.length);
    final double onNavTop = tester.getTopLeft(tooltipOf(labels.first).first).dy;
    expect(offNavTop, greaterThan(onNavTop), reason: '纯图标的悬浮底栏更矮，入口整体下沉');

    // 再关掉：标签消失。
    await toggle(tester, false);
    expect(appModel.navBarLabelsVisible, isFalse);
    await pumpShell(tester);
    expect(paintedLabels(), 0);
  });

  test('home shell feeds the bottom bar from navBarLabelsVisible', () {
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(
      compactCode(methodBody(home, 'Widget _buildMobileLayout(')),
      contains('showLabels:appModel.navBarLabelsVisible'),
    );
  });
}
