import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 防回归守卫：默认图标=文字、Windows 运行时切换通道存在、设置页跨平台。
/// 这些是无法用 widget 测试覆盖的「跨语言契约 / 资源引用」，用源码扫描兜底。
void main() {
  String read(String relative) {
    // 测试在 hibiki/ 下运行；相对路径即相对该目录。
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
    return f.readAsStringSync();
  }

  test('Android 默认启动器图标引用文字 wordmark 资源', () {
    final String manifest = read('android/app/src/main/AndroidManifest.xml');
    // <application> 与 .MainActivityDefault 都应引用 launcher_icon_minimal。
    expect(manifest.contains('@mipmap/launcher_icon_minimal'), isTrue);
    // 默认 alias 应引用文字 wordmark（launcher_icon_minimal），而非旧的響书本。
    final RegExp defaultAlias = RegExp(
      r'MainActivityDefault[\s\S]*?android:icon="@mipmap/launcher_icon_minimal"',
    );
    expect(defaultAlias.hasMatch(manifest), isTrue,
        reason: '.MainActivityDefault 应引用 launcher_icon_minimal');
  });

  test('Windows runner 暴露 setWindowIcon 通道方法', () {
    final String cpp = read('windows/runner/flutter_window.cpp');
    expect(cpp.contains('"setWindowIcon"'), isTrue);
    expect(cpp.contains('ApplyWindowIcon'), isTrue);
    expect(cpp.contains('WM_SETICON'), isTrue);
  });

  test('Dart 侧有 setWindowIcon 封装', () {
    final String dart = read('lib/src/utils/window_caption_channel.dart');
    expect(dart.contains('setWindowIcon'), isTrue);
  });

  test('设置页图标网格对 Windows 可见', () {
    final String page =
        read('lib/src/pages/implementations/miscellaneous_settings_page.dart');
    expect(page.contains('Platform.isWindows'), isTrue);
    final String schema =
        read('lib/src/settings/settings_schema_appearance.dart');
    expect(schema.contains('Platform.isWindows'), isTrue);
  });

  test('Windows app icon 用已提交的 app_icon.ico wordmark', () {
    // TODO-879（f9f5bb380）删除了 flutter_launcher_icons 配置块（generator 会
    // 覆盖手调 adaptive 图标），Windows 改用已提交的 app_icon.ico。
    // 守卫真实不变量：已提交的 ico 存在且非空 + Runner.rc 引用它。
    final File ico = File('windows/runner/resources/app_icon.ico');
    expect(ico.existsSync(), isTrue,
        reason: '缺失已提交的 Windows 图标: windows/runner/resources/app_icon.ico');
    expect(ico.lengthSync() > 0, isTrue,
        reason: 'app_icon.ico 不应为空（应是文字 wordmark 图标）');

    final String rc = read('windows/runner/Runner.rc');
    // .rc 里路径用双反斜杠转义：resources\app_icon.ico。
    final RegExp iconRef = RegExp(
      r'IDI_APP_ICON\s+ICON\s+"resources\\\\app_icon\.ico"',
    );
    expect(iconRef.hasMatch(rc), isTrue,
        reason: 'Runner.rc 应以 IDI_APP_ICON 引用 resources\\\\app_icon.ico');
  });

  test('Android 12+ 系统 splash 图标用文字 wordmark 前景', () {
    for (final String rel in <String>[
      'android/app/src/main/res/values-v31/styles.xml',
      'android/app/src/main/res/values-night-v31/styles.xml',
    ]) {
      final String styles = read(rel);
      expect(
        styles.contains('android:windowSplashScreenAnimatedIcon') &&
            styles.contains('@drawable/ic_launcher_minimal_foreground'),
        isTrue,
        reason: '$rel 的 Android 12+ splash 应显示文字 wordmark 前景'
            '（与默认启动器图标一致）',
      );
    }
  });

  test('TODO-868 去重：图标选择器只剩 default+full 两档，无重复的简约档', () {
    // 预设映射只剩两档，且不含 hibiki_minimal。
    final String prefs = read('lib/src/utils/misc/app_icon_preferences.dart');
    expect(prefs.contains("'hibiki_minimal':"), isFalse,
        reason: 'presetIconAssets 不应再映射 hibiki_minimal（与 default 重复）');
    expect(prefs.contains("'default':"), isTrue);
    expect(prefs.contains("'hibiki_full':"), isTrue);

    // 设置页不再渲染 hibiki_minimal tile，也不再引用 t.icon_minimal label。
    final String page =
        read('lib/src/pages/implementations/miscellaneous_settings_page.dart');
    expect(page.contains("key: 'hibiki_minimal'"), isFalse,
        reason: '设置页不应再渲染 hibiki_minimal 预设 tile');
    expect(page.contains('t.icon_minimal'), isFalse,
        reason: '设置页不应再引用已删除的 icon_minimal label');
  });

  test(
      'TODO-868 Android 老用户安全：minimal alias 仍声明 + IconSwitchHelper 迁移回 default',
      () {
    // manifest 保留退役 alias 声明，避免老用户升级后 launcher 图标消失。
    final String manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(manifest.contains('.MainActivityHibikiMinimal'), isTrue,
        reason: '退役 minimal alias 必须保留声明（老用户 launcher 安全）');

    // IconSwitchHelper：不再把 hibiki_minimal 列为可选项，但提供迁移逻辑。
    final String helper = read(
        'android/app/src/main/java/app/hibiki/reader/IconSwitchHelper.java');
    expect(helper.contains('"hibiki_minimal"'), isFalse,
        reason: 'hibiki_minimal 不应再出现在可选 ALIAS_KEYS 中');
    expect(helper.contains('migrateRetiredMinimalIfEnabled'), isTrue,
        reason: '必须提供老用户迁移逻辑，把启用的 minimal alias 迁回 default');
    expect(helper.contains('RETIRED_MINIMAL_ALIAS'), isTrue);
  });
}
