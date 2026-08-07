import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('sync_to_mac rejects exclusions when remote branch already exists',
      () async {
    final Directory workspace = Directory.current.parent;
    final File script = File(p.join(workspace.path, 'tool', 'sync_to_mac.ps1'));
    final Directory repo = await _createRepoWithExcludedCommit(
      remoteBranch: 'feature-existing',
      remoteBranchExists: true,
    );

    final ProcessResult result = await _runSyncToMacDryRun(
      script: script,
      repo: repo,
      branch: 'feature-existing',
    );

    _expectExcludedUploadRejected(result);
  }, skip: !Platform.isWindows);

  test('sync_to_mac rejects exclusions when creating a remote branch',
      () async {
    final Directory workspace = Directory.current.parent;
    final File script = File(p.join(workspace.path, 'tool', 'sync_to_mac.ps1'));
    final Directory repo = await _createRepoWithExcludedCommit(
      remoteBranch: 'feature-new',
      remoteBranchExists: false,
    );

    final ProcessResult result = await _runSyncToMacDryRun(
      script: script,
      repo: repo,
      branch: 'feature-new',
    );

    _expectExcludedUploadRejected(result);
  }, skip: !Platform.isWindows);

  test('sync_to_mac rejects deletion of a tracked upload exclusion', () async {
    final Directory workspace = Directory.current.parent;
    final File script = File(p.join(workspace.path, 'tool', 'sync_to_mac.ps1'));
    final Directory repo = await _createRepoDeletingTrackedExclusion(
      remoteBranch: 'feature-delete',
    );

    final ProcessResult result = await _runSyncToMacDryRun(
      script: script,
      repo: repo,
      branch: 'feature-delete',
    );

    _expectExcludedUploadRejected(
      result,
      expectedPaths: <String>['手机编译安装ARM.bat'],
    );
  }, skip: !Platform.isWindows);
}

Future<Directory> _createRepoWithExcludedCommit({
  required String remoteBranch,
  required bool remoteBranchExists,
}) async {
  final Directory workspace = Directory.current.parent;
  final File exclusionFile =
      File(p.join(workspace.path, 'tool', 'sync_upload_exclusions.txt'));
  expect(exclusionFile.existsSync(), isTrue);
  final String exclusions = exclusionFile.readAsStringSync();
  expect(exclusions, contains('手机编译安装ARM.bat'));
  expect(exclusions, contains('docs/项目负责人提示词 copy'));
  expect(exclusions, contains('docs/项目负责人提示词'));

  final Directory temp =
      await Directory.systemTemp.createTemp('hibiki_sync_to_mac_guard_');

  final Directory repo = Directory(p.join(temp.path, 'repo'))
    ..createSync(recursive: true);
  await _runGit(repo, <String>['init']);
  await _runGit(repo, <String>['checkout', '-b', remoteBranch]);
  await _runGit(repo, <String>['config', 'user.email', 'test@example.com']);
  await _runGit(repo, <String>['config', 'user.name', 'Test User']);
  await _runGit(repo, <String>['remote', 'add', 'mac', temp.path]);

  File(p.join(repo.path, 'README.md')).writeAsStringSync('base\n');
  await _runGit(repo, <String>['add', 'README.md']);
  await _runGit(repo, <String>['commit', '-m', 'base']);
  await _runGit(repo, <String>[
    'update-ref',
    'refs/remotes/mac/develop',
    'HEAD',
  ]);
  if (remoteBranchExists) {
    await _runGit(repo, <String>[
      'update-ref',
      'refs/remotes/mac/$remoteBranch',
      'HEAD',
    ]);
  }

  Directory(p.join(repo.path, 'docs')).createSync();
  File(p.join(repo.path, '手机编译安装ARM.bat')).writeAsStringSync('echo hi\n');
  File(p.join(repo.path, 'docs', '项目负责人提示词 copy'))
      .writeAsStringSync('local copy\n');
  File(p.join(repo.path, 'docs', '项目负责人提示词'))
      .writeAsStringSync('local prompt\n');
  await _runGit(repo, <String>['add', '.']);
  await _runGit(repo, <String>['commit', '-m', 'touch local-only files']);

  addTearDown(() => temp.delete(recursive: true));
  return repo;
}

Future<Directory> _createRepoDeletingTrackedExclusion({
  required String remoteBranch,
}) async {
  final Directory temp =
      await Directory.systemTemp.createTemp('hibiki_sync_to_mac_delete_guard_');

  final Directory repo = Directory(p.join(temp.path, 'repo'))
    ..createSync(recursive: true);
  await _runGit(repo, <String>['init']);
  await _runGit(repo, <String>['checkout', '-b', remoteBranch]);
  await _runGit(repo, <String>['config', 'user.email', 'test@example.com']);
  await _runGit(repo, <String>['config', 'user.name', 'Test User']);
  await _runGit(repo, <String>['remote', 'add', 'mac', temp.path]);

  File(p.join(repo.path, 'README.md')).writeAsStringSync('base\n');
  File(p.join(repo.path, '手机编译安装ARM.bat')).writeAsStringSync('tracked\n');
  await _runGit(repo, <String>['add', '.']);
  await _runGit(repo, <String>['commit', '-m', 'base with tracked exclusion']);
  await _runGit(repo, <String>[
    'update-ref',
    'refs/remotes/mac/develop',
    'HEAD',
  ]);
  await _runGit(repo, <String>[
    'update-ref',
    'refs/remotes/mac/$remoteBranch',
    'HEAD',
  ]);

  File(p.join(repo.path, '手机编译安装ARM.bat')).deleteSync();
  await _runGit(repo, <String>['add', '-u']);
  await _runGit(repo, <String>['commit', '-m', 'delete tracked exclusion']);

  addTearDown(() => temp.delete(recursive: true));
  return repo;
}

Future<ProcessResult> _runSyncToMacDryRun({
  required File script,
  required Directory repo,
  required String branch,
}) {
  expect(script.existsSync(), isTrue);
  return Process.run(
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
      branch,
      '-DryRun',
    ],
    workingDirectory: repo.path,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
}

void _expectExcludedUploadRejected(
  ProcessResult result, {
  List<String> expectedPaths = const <String>[
    '手机编译安装ARM.bat',
    'docs/项目负责人提示词 copy',
    'docs/项目负责人提示词',
  ],
}) {
  final String output = '${result.stdout}\n${result.stderr}';
  expect(result.exitCode, isNot(0), reason: output);
  expect(output, contains('excluded from Mac upload'));
  for (final String path in expectedPaths) {
    expect(output, contains(path));
  }
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
