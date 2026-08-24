import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1836 守卫：**每一条**发布构建都必须把 build-name 同时注入 Dart。
///
/// `--build-name` 只写进原生版本资源。Windows 的 VERSIONINFO 只能存 4 段数字 +
/// 一个由 Flutter 生成的字符串，`-debug.12215` 这段后缀在那里**必然丢失**，而且它
/// 和 `app.so` 是两个文件——「新 exe + 旧 app.so」的半更新态里它照样报新版本。
/// 所以「运行中的代码是哪个构建」这条证据只能靠
/// `--dart-define=FUSHI_BUILD_VERSION`（编译进 AOT 快照，与产物同体）。
///
/// 漏在任何一条构建上，那个平台/通道的包就退回「只能靠 Inno 日志判断装没装上」的
/// 老状态：手动装包救援必报失败（BUG-1836），半更新态无法自检（BUG-1786）。
void main() {
  const String defineName = 'FUSHI_BUILD_VERSION';

  Directory workflowsDir() {
    // 测试 cwd 是 `fushi/`。
    final Directory dir = Directory('../.github/workflows');
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'expected workflows at ${dir.absolute.path}',
    );
    return dir;
  }

  /// 按 `- name:` 切成步骤：构建命令绝不会跨两个步骤，用它当边界比固定行窗口
  /// 可靠（固定窗口会被新增注释顶出范围，守卫悄悄失效 —— BUG-1831 踩过一次）。
  List<String> splitSteps(String yaml) {
    final List<String> steps = <String>[];
    final StringBuffer current = StringBuffer();
    for (final String line in const LineSplitter().convert(yaml)) {
      if (RegExp(r'^\s*-\s+name:').hasMatch(line)) {
        if (current.isNotEmpty) steps.add(current.toString());
        current.clear();
      }
      current.writeln(line);
    }
    if (current.isNotEmpty) steps.add(current.toString());
    return steps;
  }

  test('每处 --build-name 都配了同值的 --dart-define=$defineName', () {
    int checked = 0;
    for (final File file in workflowsDir().listSync().whereType<File>().where(
      (File f) => f.path.endsWith('.yml'),
    )) {
      for (final String step in splitSteps(file.readAsStringSync())) {
        final Iterable<RegExpMatch> buildNames = RegExp(
          r'--build-name\s+"([^"]*)"',
        ).allMatches(step);
        for (final RegExpMatch match in buildNames) {
          final String value = match.group(1)!;
          checked++;
          expect(
            step,
            contains('--dart-define="$defineName=$value"'),
            reason:
                '${file.path} 里有一处 --build-name "$value" 没同时注入 Dart；'
                '该平台的包将无法自报运行中代码的版本',
          );
        }
      }
    }
    expect(
      checked,
      greaterThanOrEqualTo(7),
      reason:
          '发布构建点少于预期（Windows / macOS / iOS / IPA / 三条 APK）——'
          '要么有构建被删了，要么 --build-name 换了写法让这条守卫扫空',
    );
  });

  test('Dart 侧确实读这个 define（两侧名字必须同时改）', () {
    final File source = File('lib/src/utils/misc/build_version.dart');
    expect(source.existsSync(), isTrue);
    // 断言字面量（勿改）: 'FUSHI_BUILD_VERSION'
    //
    // 先抹掉所有空白再匹配：`dart format` 的 tall style 会把这行折成三行，
    // 单行字面量断言会**恒不匹配**而不是报错——守卫悄悄失效比没有守卫更糟。
    expect(
      source.readAsStringSync().replaceAll(RegExp(r'\s+'), ''),
      contains("String.fromEnvironment('$defineName')"),
      reason: '构建期注入的名字和 Dart 侧读的名字对不上，注入就是白注入',
    );
  });
}
