import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 回归守卫：runner 的原生测试 exe 不得进 Windows 安装包。
///
/// 根因：`fushi_windows_*_test` 是构建期门禁（`*_gate` 经 `$<TARGET_FILE:>`
/// 调用），却与 `fushi.exe` 同在 `windows/runner/CMakeLists.txt`、默认输出到同一个
/// `runner/<Config>/`——那个目录就是 Flutter bundle，`fushi.iss` 用
/// `Source: "{#SourceDir}\*"` 整目录收包，于是 3.0 及更早的安装包把 29 个测试 exe
/// （全局鼠标钩子 / PrintWindow 截屏 / 读剪贴板之类）装进了用户的 `{app}`。
///
/// 修复：runner/CMakeLists.txt **末尾**按命名约定把全部 `fushi_windows_*_test`
/// 目标的 RUNTIME_OUTPUT_DIRECTORY 挪到 bundle 之外；安装器 `[InstallDelete]`
/// 清掉旧版留下的那批。发布 workflow 另在装完后回验 `{app}` 里没有 `*_test.exe`。
void main() {
  final Directory runnerDir = Directory('windows/runner');

  String readCmake(File file) {
    expect(file.existsSync(), isTrue, reason: 'missing ${file.absolute.path}');
    return maskHashComments(file.readAsStringSync());
  }

  List<File> runnerCmakeFiles() => <File>[
    File('${runnerDir.path}/CMakeLists.txt'),
    ...Directory(
      '${runnerDir.path}/tests',
    ).listSync().whereType<File>().where((File f) => f.path.endsWith('.cmake')),
  ];

  final RegExp addExecutable = RegExp(r'add_executable\(\s*([A-Za-z0-9_]+)');
  final RegExp testTargetPattern = RegExp(r'^fushi_windows_.+_test$');

  test(
    'every runner test executable follows the redirected naming pattern',
    () {
      final List<String> offenders = <String>[];
      int testTargets = 0;
      for (final File file in runnerCmakeFiles()) {
        for (final RegExpMatch m in addExecutable.allMatches(readCmake(file))) {
          final String name = m.group(1)!;
          if (!name.endsWith('_test')) continue;
          testTargets++;
          if (!testTargetPattern.hasMatch(name)) {
            offenders.add('${file.path}: $name');
          }
        }
      }
      expect(
        testTargets,
        greaterThan(0),
        reason: '没扫到任何 runner 测试目标——扫描面失效，守卫成了空壳',
      );
      expect(
        offenders,
        isEmpty,
        reason:
            '这些测试目标不匹配 ^fushi_windows_.+_test\$，CMakeLists 末尾的'
            '输出目录重定向兜不住它们，会被 fushi.iss 整目录收进安装包',
      );
    },
  );

  test(
    'test output is redirected out of the bundle after all targets exist',
    () {
      final String cmake = readCmake(File('${runnerDir.path}/CMakeLists.txt'));
      final int redirect = cmake.indexOf(
        RegExp(
          r'get_property\(\s*\w+\s+DIRECTORY\s+PROPERTY\s+'
          r'BUILDSYSTEM_TARGETS\s*\)',
        ),
      );
      expect(
        redirect,
        greaterThanOrEqualTo(0),
        reason: 'runner/CMakeLists.txt 必须按 BUILDSYSTEM_TARGETS 统一重定向测试输出',
      );

      final String tail = cmake.substring(redirect);
      expect(tail.contains(r'MATCHES "^fushi_windows_.+_test$"'), isTrue);
      expect(
        RegExp(
          r'RUNTIME_OUTPUT_DIRECTORY\s+"\$\{CMAKE_CURRENT_BINARY_DIR\}/'
          r'native_tests"',
        ).hasMatch(tail),
        isTrue,
        reason: '测试 exe 必须输出到 bundle（runner/<Config>/）之外',
      );

      // BUILDSYSTEM_TARGETS 只含**调用时已定义**的目标：重定向之后再加的测试会漏网。
      expect(
        addExecutable.hasMatch(tail),
        isFalse,
        reason: '重定向块之后不得再 add_executable，把它挪到重定向块之前',
      );
      expect(
        RegExp(r'\binclude\(').hasMatch(tail),
        isFalse,
        reason: '重定向块之后不得再 include()（被 include 的文件可能定义测试目标）',
      );
    },
  );

  test('installer removes test executables left by older packages', () {
    final File iss = File('windows/installer/fushi.iss');
    expect(iss.existsSync(), isTrue);
    final String src = iss.readAsStringSync();
    final int start = src.indexOf('[InstallDelete]');
    final int end = src.indexOf('[Files]', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final bool hasDirective = src
        .substring(start, end)
        .split('\n')
        .map((String line) => line.trim())
        .any(
          (String line) =>
              !line.startsWith(';') &&
              line.contains(r'Name: "{app}\*_windows_*_test.exe"'),
        );
    expect(
      hasDirective,
      isTrue,
      reason: '升级必须清掉旧版装进 {app} 的 fushi_/hibiki_windows_*_test.exe',
    );
  });
}
