import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('sync_to_mac dry-run rejects commits touching upload exclusions',
      () async {
    final Directory workspace = Directory.current.parent;
    final File script = File(p.join(workspace.path, 'tool', 'sync_to_mac.ps1'));
    final File exclusionFile =
        File(p.join(workspace.path, 'tool', 'sync_upload_exclusions.txt'));
    expect(script.existsSync(), isTrue);
    expect(exclusionFile.existsSync(), isTrue);
    final String exclusions = exclusionFile.readAsStringSync();
    expect(exclusions, contains('手机编译安装ARM.bat'));
    expect(exclusions, contains('docs/项目负责人提示词 copy'));
    expect(exclusions, contains('docs/项目负责人提示词'));

    final Directory temp =
        await Directory.systemTemp.createTemp('hibiki_sync_to_mac_guard_');
    addTearDown(() => temp.delete(recursive: true));

    final Directory repo = Directory(p.join(temp.path, 'repo'))
      ..createSync(recursive: true);
    await _runGit(repo, <String>['init']);
    await _runGit(repo, <String>['checkout', '-b', 'main']);
    await _runGit(repo, <String>['config', 'user.email', 'test@example.com']);
    await _runGit(repo, <String>['config', 'user.name', 'Test User']);
    await _runGit(repo, <String>['remote', 'add', 'mac', temp.path]);

    File(p.join(repo.path, 'README.md')).writeAsStringSync('base\n');
    await _runGit(repo, <String>['add', 'README.md']);
    await _runGit(repo, <String>['commit', '-m', 'base']);
    await _runGit(repo, <String>[
      'update-ref',
      'refs/remotes/mac/main',
      'HEAD',
    ]);

    Directory(p.join(repo.path, 'docs')).createSync();
    File(p.join(repo.path, '手机编译安装ARM.bat')).writeAsStringSync('echo hi\n');
    File(p.join(repo.path, 'docs', '项目负责人提示词 copy'))
        .writeAsStringSync('local copy\n');
    File(p.join(repo.path, 'docs', '项目负责人提示词'))
        .writeAsStringSync('local prompt\n');
    await _runGit(repo, <String>['add', '.']);
    await _runGit(repo, <String>['commit', '-m', 'touch local-only files']);

    final ProcessResult result = await Process.run(
      'powershell',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Remote',
        'mac',
        '-Branch',
        'main',
        '-DryRun',
      ],
      workingDirectory: repo.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    final String output = '${result.stdout}\n${result.stderr}';
    expect(result.exitCode, isNot(0), reason: output);
    expect(output, contains('excluded from Mac upload'));
    expect(output, contains('手机编译安装ARM.bat'));
    expect(output, contains('docs/项目负责人提示词 copy'));
    expect(output, contains('docs/项目负责人提示词'));
  }, skip: !Platform.isWindows);
}

Future<void> _runGit(Directory repo, List<String> args) async {
  final ProcessResult result = await Process.run(
    'git',
    args,
    workingDirectory: repo.path,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'git ${args.join(' ')} failed\n${result.stdout}\n${result.stderr}',
    );
  }
}
