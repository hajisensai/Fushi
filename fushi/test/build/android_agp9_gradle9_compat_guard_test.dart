import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 守卫：Flutter 3.50 起 Android 工具链下限是 Gradle 9.5.0 / AGP 9.3.1 / KGP 2.4.20
/// （3.50 Flutter Gradle 插件 `DependencyVersionChecker` 的硬下限是 9.3.1 / 9.1.1 / 2.4.10，低了直接拒绝构建；
/// 低于 9.5.0 / 9.3.1 / 2.4.20 会报「即将不再支持」，BUG-5148 已升到这一档，守卫按它钉）。
///
/// PR #3400 迁移时在 CI 上逐个撞出来的配置期 / 构建期失败，这里钉住不回退：
///
/// - wrapper / settings 插件钉点不得低于下限；
/// - Gradle 9 删了 `jcenter()`，Groovy 4 的 `XmlParser` 只在 `groovy.xml` 包里——
///   根 `build.gradle` 与本仓随包的插件（`third_party/*`、`packages/*`）都不能再用；
/// - AGP 9 拒绝 `getDefaultProguardFile('proguard-android.txt')`（带 `-dontoptimize`）；
/// - AGP 9 对每个 library 模块跑 `check*AarMetadata`：插件 compileSdk 必须不低于依赖
///   的 minCompileSdk（`flutter_plugin_android_lifecycle`、androidx.camera 1.6 要 36），
///   根 `build.gradle` 不得再把插件压到 36 以下。
void main() {
  // 测试 cwd 是 `fushi/`。
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '${file.absolute.path} 不存在');
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  List<int> versionOf(String text, RegExp pattern, String what) {
    final RegExpMatch? m = pattern.firstMatch(text);
    expect(m, isNotNull, reason: '找不到 $what 的版本钉点');
    return m!.group(1)!.split('.').map(int.parse).toList();
  }

  bool atLeast(List<int> actual, List<int> floor) {
    for (int i = 0; i < floor.length; i++) {
      final int a = i < actual.length ? actual[i] : 0;
      if (a != floor[i]) return a > floor[i];
    }
    return true;
  }

  test('Gradle wrapper >= 9.5.0', () {
    final List<int> v = versionOf(
      read('android/gradle/wrapper/gradle-wrapper.properties'),
      RegExp(r'gradle-(\d+\.\d+(?:\.\d+)?)-(?:all|bin)\.zip'),
      'Gradle wrapper',
    );
    expect(atLeast(v, <int>[9, 5, 0]), isTrue, reason: 'Gradle $v < 9.5.0');
  });

  test('settings.gradle：AGP >= 9.3.1，KGP 系插件 >= 2.4.20', () {
    final String settings = maskComments(read('android/settings.gradle'));
    final List<int> agp = versionOf(
      settings,
      RegExp(r'id "com\.android\.application" version "([\d.]+)"'),
      'AGP',
    );
    expect(atLeast(agp, <int>[9, 3, 1]), isTrue, reason: 'AGP $agp < 9.3.1');
    final Iterable<RegExpMatch> kotlinPlugins = RegExp(
      r'id "org\.jetbrains\.kotlin\.[\w.]+" version "([\d.]+)"',
    ).allMatches(settings);
    expect(kotlinPlugins, isNotEmpty);
    for (final RegExpMatch m in kotlinPlugins) {
      final List<int> v = m.group(1)!.split('.').map(int.parse).toList();
      expect(
        atLeast(v, <int>[2, 4, 20]),
        isTrue,
        reason: '${m.group(0)} < 2.4.20',
      );
    }
  });

  List<File> vendoredAndroidScripts() {
    final List<File> out = <File>[File('android/build.gradle')];
    for (final String root in <String>['../third_party', '../packages']) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity pkg in dir.listSync()) {
        if (pkg is! Directory) continue;
        for (final String name in <String>[
          'build.gradle',
          'build.gradle.kts',
        ]) {
          final File f = File('${pkg.path}/android/$name');
          if (f.existsSync()) out.add(f);
        }
      }
    }
    return out;
  }

  test('随包 Android 脚本不用 Gradle 9 / Groovy 4 / AGP 9 已删的写法', () {
    final List<File> scripts = vendoredAndroidScripts();
    // 扫描范围必须真的覆盖到随包插件，否则这条守卫是空转。
    expect(
      scripts.map((File f) => f.path.replaceAll(r'\', '/')),
      containsAll(<Matcher>[
        contains('third_party/receive_intent/android/build.gradle'),
        contains('third_party/flutter_inappwebview_android/android/'),
        contains('third_party/desktop_drop/android/build.gradle'),
      ]),
    );
    final List<String> offenders = <String>[];
    for (final File f in scripts) {
      final String code = maskComments(
        f.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      if (RegExp(r'\bjcenter\s*\(').hasMatch(code)) {
        offenders.add('${f.path}: jcenter()（Gradle 9 已删）');
      }
      if (RegExp(r'(?<![\w.])XmlParser\s*\(').hasMatch(code)) {
        offenders.add(
          '${f.path}: 裸 XmlParser（Groovy 4 要 groovy.xml.XmlParser）',
        );
      }
      if (code.contains("getDefaultProguardFile('proguard-android.txt')") ||
          code.contains('getDefaultProguardFile("proguard-android.txt")')) {
        offenders.add('${f.path}: proguard-android.txt（AGP 9 拒绝）');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('根 build.gradle 不把插件 compileSdk 压到 36 以下', () {
    final String root = maskComments(read('android/build.gradle'));
    final Iterable<RegExpMatch> sets = RegExp(
      r'android\.compileSdk(?:Version)?\s*=?\s*(\d+)',
    ).allMatches(root);
    expect(sets, isNotEmpty, reason: '根 build.gradle 应统一设插件 compileSdk');
    for (final RegExpMatch m in sets) {
      expect(
        int.parse(m.group(1)!),
        greaterThanOrEqualTo(36),
        reason: '${m.group(0)}：AGP 9 的 library AAR 元数据校验要求 >= 36',
      );
    }
  });
}
