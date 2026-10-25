import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// `flutter test --experimental-faster-testing`（CI 单测分片用它；PR #2422 的随机 SIGSEGV
/// 见 `packages/fushi_ffi_view`）把上千个 suite 放在**同一个进程**里各起一个 isolate 跑。
/// 进程级状态因此是所有 suite 共享的，
/// 其中最致命的是工作目录——`bug_tool_*` 测试曾把 `Directory.current` 切进临时 fixture
/// 仓库，同时在跑的 15 个 suite 读 `lib/…` / `test/…` / `tool/…` 相对路径全部
/// PathNotFound（PR #2422 第一轮 CI）。
///
/// 要在别的目录下操作，就把目录传给被测代码（`tool/bug.dart` 的 `bugRepoRoot`），或给
/// 子进程传 `workingDirectory`；测试本身不许改进程的工作目录。
void main() {
  final RegExp cwdAssignment = RegExp(r'\bDirectory\.current\s*=(?!=)');

  test('tests never change the process working directory', () {
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final String root in <String>['test', 'integration_test']) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity entity in dir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        scanned++;
        final String code = maskCommentsAndStrings(entity.readAsStringSync());
        if (cwdAssignment.hasMatch(code)) {
          offenders.add(entity.path.replaceAll(r'\', '/'));
        }
      }
    }
    expect(scanned, greaterThan(1000), reason: '扫描面塌了：test/ 没被枚举到');
    expect(
      offenders,
      isEmpty,
      reason:
          '这些测试改了进程级工作目录，会让同进程并发的其它 suite 读错相对路径；'
          '把目录传给被测代码，或给子进程传 workingDirectory。',
    );
  });

  test('the pattern catches an assignment and ignores comparisons', () {
    expect(cwdAssignment.hasMatch('Directory.current = root;'), isTrue);
    expect(cwdAssignment.hasMatch('Directory.current=root;'), isTrue);
    expect(cwdAssignment.hasMatch('if (Directory.current == d) {}'), isFalse);
    expect(cwdAssignment.hasMatch('final d = Directory.current;'), isFalse);
  });
}
