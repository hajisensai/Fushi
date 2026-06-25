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

  test('pubspec Windows 图标源是文字 wordmark', () {
    final String pubspec = read('pubspec.yaml');
    final RegExp windowsIcon = RegExp(
      r'windows:[\s\S]*?image_path:\s*"assets/meta/launcher_icon_minimal\.png"',
    );
    expect(windowsIcon.hasMatch(pubspec), isTrue);
  });
}
