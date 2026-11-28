import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 横屏手机版面巡检：把设备转到横屏后逐个顶层 tab、设置详情、快捷键（手柄）页
/// 截一帧真像素，用来找「横屏下控件把内容挤没 / 空出大片」这类问题。
///
/// 跑法（Android 模拟器，先 `adb shell settings put system user_rotation 1`）：
///   flutter drive --driver=test_driver/integration_test_screenshots.dart
///     --target=integration_test/landscape_phone_sweep_itest.dart -d emulator-5554
/// 截图落在 `fushi/screenshots/`。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('landscape phone layout sweep', (WidgetTester tester) async {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
    ]);
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    _binding = binding;
    final AppModel appModel = await readyAppModel(tester);
    await _settle(tester, 3);

    // 新装默认关掉的模块也打开，巡检覆盖每个 tab（测试安装，用完即弃）。
    for (final ModuleId module in ModuleId.values) {
      if (!appModel.moduleVisibility.isEnabled(module)) {
        try {
          await appModel.setModuleEnabled(module, true);
        } catch (_) {}
      }
    }
    await _settle(tester, 2);

    final Size logical =
        tester.view.physicalSize / tester.view.devicePixelRatio;
    debugPrint(
      '[landscape-sweep] logical=${logical.width}x${logical.height} '
      'padding=${tester.view.padding} '
      'design=${appModel.themeNotifier.designSystem}',
    );

    int index = 0;
    final String designBefore = appModel.themeNotifier.designSystem;
    try {
      for (final String design in <String>['material', 'glass']) {
        await appModel.themeNotifier.setDesignSystem(design);
        await _settle(tester, 2);
        final List<HomeTab> tabs = homeActiveTabs(appModel.moduleVisibility);
        for (final HomeTab tab in tabs) {
          HomePage.debugSelectTab?.call(tab);
          await _settle(tester, 3);
          await _shot(tester, '${_n(index++)}-$design-tab-${tab.name}');
        }

        final NavigatorState navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        // 前几个设置分类（与设置首页同一份 schema，按可见性过滤）。
        for (int d = 0; d < 4; d++) {
          String name = 'none';
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? _) {
                  final SettingsContext settingsContext = SettingsContext(
                    context: context,
                    appModel: appModel,
                    ref: ref,
                    readerSource: ReaderFushiSource.instance,
                    refresh: () {},
                  );
                  final List<SettingsDestination> visible =
                      buildSettingsSchema(settingsContext)
                          .where(
                            (SettingsDestination x) =>
                                x.isVisible(settingsContext),
                          )
                          .toList();
                  final SettingsDestination destination = visible[d];
                  name = destination.id.name;
                  return SettingsDetailPage(destination: destination);
                },
              ),
            ),
          );
          await _settle(tester, 2);
          await _shot(tester, '${_n(index++)}-$design-settings-$d-$name');
          navigator.pop();
          await _settle(tester, 1);
        }

        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const ShortcutSettingsPage()),
        );
        await _settle(tester, 2);
        await _shot(tester, '${_n(index++)}-$design-shortcuts-keyboard');

        // 切到手柄设备：焦点驱动（让分段控件拿焦点，方向键右移两格）。
        final Finder toggle = find.byKey(const Key('shortcut_device_toggle'));
        if (toggle.evaluate().isNotEmpty) {
          final Focus focus = tester.widget<Focus>(
            find.descendant(of: toggle, matching: find.byType(Focus)).first,
          );
          focus.focusNode?.requestFocus();
          await tester.pump();
          for (int i = 0; i < 2; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await _settle(tester, 1);
          }
          await _shot(tester, '${_n(index++)}-$design-shortcuts-gamepad');
          // 往下滚一段：矮视口下工具区应随列表滚走、只留分组标题吸顶。
          final ScrollableState results = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const ValueKey<String>('shortcut-results')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          results.position.jumpTo(260);
          await _settle(tester, 1);
          await _shot(
            tester,
            '${_n(index++)}-$design-shortcuts-gamepad-scrolled',
          );
        }
        navigator.pop();
        await _settle(tester, 1);
      }
    } finally {
      await appModel.themeNotifier.setDesignSystem(designBefore);
    }
    debugPrint('[landscape-sweep] done shots=$index');
  });
}

String _n(int i) => i.toString().padLeft(2, '0');

Future<void> _settle(WidgetTester tester, int seconds) async {
  for (int i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

late IntegrationTestWidgetsFlutterBinding _binding;
bool _surfaceConverted = false;

/// 截图经 driver 回传宿主（`test_driver/integration_test_screenshots.dart` 写进
/// `screenshots/`）：`flutter drive` 结束会卸载 app，留在设备上的文件取不回来。
Future<void> _shot(WidgetTester tester, String name) async {
  if (!_surfaceConverted) {
    await _binding.convertFlutterSurfaceToImage();
    _surfaceConverted = true;
  }
  await tester.pump();
  final List<int> bytes = await _binding.takeScreenshot(name);
  debugPrint('[landscape-sweep] $name bytes=${bytes.length}');
}
