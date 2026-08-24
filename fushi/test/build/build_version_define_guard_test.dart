import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1836 守卫：**每一条**发布构建都必须把 build-name 同时注入 Dart。
///
/// `--build-name` 只写进原生版本资源（exe VERSIONINFO / Info.plist / manifest），
/// 那和 `app.so` 是**两个文件**——Inno 的回滚保留被覆盖的文件、只删本次新建的
/// 文件，「新 exe + 旧 app.so」的半更新态照样落地，版本资源却报新版本
/// （BUG-1786）。「运行中的代码是哪个构建」这条证据只能靠
/// `--dart-define=FUSHI_BUILD_VERSION`：它编译进 AOT 快照，与产物同体。
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

  /// 按 YAML 列表项切成步骤：构建命令绝不会跨两个步骤，用它当边界比固定行窗口
  /// 可靠（固定窗口会被新增注释顶出范围，守卫悄悄失效——BUG-1831 踩过一次）。
  ///
  /// 边界认**任意**以 `- <key>:` 打头的行，而不只是 `- name:`：步骤不一定把
  /// `name` 写在第一行，只认 `name` 会把两个步骤并成一个，让 A 步的 define 去满足
  /// B 步的 build-name。
  List<String> splitSteps(String yaml) {
    final RegExp boundary = RegExp(r'^\s*-\s+[A-Za-z_][A-Za-z0-9_-]*:');
    final List<String> steps = <String>[];
    final StringBuffer current = StringBuffer();
    for (final String line in const LineSplitter().convert(yaml)) {
      if (boundary.hasMatch(line)) {
        if (current.isNotEmpty) steps.add(current.toString());
        current.clear();
      }
      current.writeln(line);
    }
    if (current.isNotEmpty) steps.add(current.toString());
    return steps;
  }

  /// 去掉参数值外层的引号（`"x"` / `'x'` / 裸 `x` 一律归成 `x`）。
  ///
  /// 匹配时**不假设写法带双引号**：新增一处 `--build-name $VAR` 若扫不到，既不会
  /// 被断言、也不会让计数掉下下界——那正是守卫悄悄失效的形状。
  String unquote(String token) {
    if (token.length >= 2) {
      final String first = token[0];
      final String last = token[token.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return token.substring(1, token.length - 1);
      }
    }
    return token;
  }

  /// `--<flag> <value>` / `--<flag>=<value>` 的取值模式。
  ///
  /// 值可能带引号且**引号里有空格**（`"${{ steps.channel.outputs.x }}"`），所以
  /// 不能只用 `\S+` —— 那会在第一个空格处截断，把整条断言变成拿半截字符串去比，
  /// 恒不匹配。
  String argumentPattern(String flag) {
    const String value = r'''("[^"]*"|'[^']*'|\S+)''';
    return '--$flag[=\\s]+$value';
  }

  test('每处 --build-name 都配了同值的 --dart-define=$defineName', () {
    int checked = 0;
    final List<File> files = workflowsDir()
        .listSync()
        .whereType<File>()
        .where(
          (File f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'),
        )
        .toList();
    expect(files, isNotEmpty, reason: '没扫到任何 workflow 文件，路径错了');

    for (final File file in files) {
      for (final String step in splitSteps(file.readAsStringSync())) {
        for (final RegExpMatch match
            in RegExp(argumentPattern('build-name')).allMatches(step)) {
          final String value = unquote(match.group(1)!);
          checked++;
          final Iterable<String> defines =
              RegExp(argumentPattern('dart-define'))
                  .allMatches(step)
                  .map((RegExpMatch m) => unquote(m.group(1)!));
          expect(
            defines,
            contains('$defineName=$value'),
            reason: '${file.path} 里有一处 --build-name $value 没同时注入 Dart；'
                '该平台的包将无法自报运行中代码的版本',
          );
        }
      }
    }
    expect(
      checked,
      greaterThanOrEqualTo(7),
      reason: '发布构建点少于预期（Windows / macOS / iOS / IPA / 三条 APK）——'
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
