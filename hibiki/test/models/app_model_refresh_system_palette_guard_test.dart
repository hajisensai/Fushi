import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';

import '../helpers/test_platform_services.dart';

/// 回归守卫：[AppModel.refreshSystemPalette] 在 `themeNotifier` 初始化之前被调用
/// 也必须安全返回。
///
/// 触发路径是真实的：`main.dart` 的系统主题广播监听器（WM_SETTINGCHANGE /
/// THEMECHANGED 等）在 app 启动早期就可能触发，而 `themeNotifier` 是
/// [AppModel.initialise] 中途才装上的（`_themeListenerAdded` 之前访问会抛
/// LateInitializationError）。getter 里的 `_themeListenerAdded` 早退就是为此。
///
/// 这条用例原本住在 `target_language_late_init_guard_test.dart` 里（与
/// targetLanguage 无关，只是搭了同一份 AppModel 构造脚手架）。2026-07-26 删除
/// targetLanguage 假抽象时整文件被删，把它一并带走了——这里恢复，独立成文件，
/// 不再挂靠别的主题。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_refresh_palette_guard');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  test('refreshSystemPalette is safe before themeNotifier initialises',
      () async {
    // 没跑 initialise()：themeNotifier 尚未装载，正是崩溃窗口。
    final AppModel appModel = AppModel(testPlatformServices());

    await expectLater(
      Future<void>.sync(appModel.refreshSystemPalette),
      completes,
    );
  });
}
