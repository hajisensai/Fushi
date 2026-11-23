import 'dart:io';

import 'package:fushi_engine/utils/process/system_command.dart';
import 'package:test/test.dart';

/// 表内 macOS 自带命令经 [systemCommand] 给绝对路径（防御性，见
/// `kMacosSystemCommandPaths` 的注释：Dart 3.14 的 posix_spawn 改动只影响传了
/// 与父进程不同 PATH 的调用）。
void main() {
  test('macOS 上表内命令给绝对路径，其余平台原样', () {
    expect(systemCommand('lsof', macos: true), '/usr/sbin/lsof');
    expect(systemCommand('scutil', macos: true), '/usr/sbin/scutil');
    expect(systemCommand('ps', macos: true), '/bin/ps');
    expect(systemCommand('say', macos: true), '/usr/bin/say');
    expect(systemCommand('defaults', macos: true), '/usr/bin/defaults');
    expect(systemCommand('lsof', macos: false), 'lsof');
    expect(systemCommand('espeak-ng', macos: true), 'espeak-ng');
    for (final String path in kMacosSystemCommandPaths.values) {
      expect(path, startsWith('/'));
    }
  });

  test('lib 代码不再用裸名调这些 macOS 系统命令', () {
    final String names = kMacosSystemCommandPaths.keys.join('|');
    final RegExp bare = RegExp(
      r'Process\.(run|runSync|start)\(\s*'
      "'($names)'",
    );
    final List<Directory> roots = <Directory>[Directory('../../fushi/lib')];
    for (final FileSystemEntity e in Directory('..').listSync()) {
      final Directory lib = Directory('${e.path}/lib');
      if (e is Directory && lib.existsSync()) roots.add(lib);
    }
    int scanned = 0;
    final List<String> offenders = <String>[];
    for (final Directory root in roots) {
      expect(root.existsSync(), isTrue, reason: root.absolute.path);
      for (final FileSystemEntity f in root.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        scanned++;
        if (bare.hasMatch(f.readAsStringSync())) offenders.add(f.path);
      }
    }
    expect(scanned, greaterThan(1000));
    expect(offenders, isEmpty, reason: '改用 systemCommand(...)');
  });
}
