// Contract: the dist_test snapshot ships the working tree but never the real
// value of a skip-worktree file (tool/setup_worktree.ps1 keeps the real OAuth /
// log-upload secrets there). See docs/specs/2026-10-24-distributed-unit-tests.md §1.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_snapshot.dart';
import '../../tool/test_flow/dist_workers.dart';

Future<String> _git(
  Directory repo,
  List<String> args, {
  Map<String, String>? environment,
}) async {
  final ProcessResult r = await Process.run(
    'git',
    args,
    workingDirectory: repo.path,
    environment: environment,
  );
  if (r.exitCode != 0) {
    throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }
  return (r.stdout as String).trim();
}

Future<String> _blob(Directory repo, String rev) =>
    _git(repo, <String>['rev-parse', rev]);

void main() {
  late Directory repo;
  late Directory scratch;
  late GitRunner git;

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('dist_snapshot_repo_');
    scratch = Directory.systemTemp.createTempSync('dist_snapshot_scratch_');
    git = gitIn(repo.path);
    await _git(repo, <String>['init', '-q']);
    await _git(repo, <String>['config', 'user.email', 't@example.com']);
    await _git(repo, <String>['config', 'user.name', 't']);
    await _git(repo, <String>['config', 'core.autocrlf', 'false']);
    Directory('${repo.path}/lib').createSync();
    File(
      '${repo.path}/lib/secret.dart',
    ).writeAsStringSync("const String secret = '';\n");
    File('${repo.path}/lib/code.dart').writeAsStringSync('int a = 1;\n');
    await _git(repo, <String>['add', '-A']);
    await _git(repo, <String>['commit', '-q', '-m', 'base']);
  });

  tearDown(() {
    repo.deleteSync(recursive: true);
    scratch.deleteSync(recursive: true);
  });

  test('clean tree: the snapshot is HEAD itself', () async {
    final DistSnapshot s = await createDistSnapshot(git, scratchDir: scratch);
    expect(s.isHead, isTrue);
    expect(s.commit, await _blob(repo, 'HEAD'));
    expect(s.base, s.commit);
  });

  test('the next run pushes only what is new, though each run deletes its '
      'own ref', () async {
    // A worker checkout: receive-pack advertises its refs, never the
    // detached HEAD the batches run on, so only refs/dist/base can tell the
    // next push what the worker already has.
    final Directory worker = Directory.systemTemp.createTempSync(
      'dist_snapshot_worker_',
    );
    addTearDown(() => worker.deleteSync(recursive: true));
    await _git(worker, <String>['init', '-q']);
    // History worth skipping: a pack of these would dwarf the change below.
    for (int i = 0; i < 20; i++) {
      File('${repo.path}/lib/f$i.dart').writeAsStringSync('int f$i = $i;\n');
      await _git(repo, <String>['add', '-A']);
      await _git(repo, <String>['commit', '-q', '-m', 'c$i']);
    }

    // Objects the push of a fresh snapshot sent, as the sender counts them:
    // the worker's own object count cannot tell, since a small pack is
    // unpacked there and the objects it already had are dropped silently.
    Future<int> push(String runId) async {
      final DistSnapshot s = await createDistSnapshot(git, scratchDir: scratch);
      final ProcessResult r = await Process.run('git', <String>[
        'push',
        '--progress',
        worker.path,
        ...distPushRefspecs(s, runId),
      ], workingDirectory: repo.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      // What the run's `finish` does.
      await _git(worker, <String>['update-ref', '-d', 'refs/dist/$runId']);
      expect(await _git(worker, <String>['rev-parse', kDistBaseRef]), s.base);
      final RegExpMatch? total = RegExp(
        r'Total (\d+)',
      ).firstMatch('${r.stderr}');
      expect(total, isNotNull, reason: '${r.stderr}');
      return int.parse(total!.group(1)!);
    }

    expect(await push('run1'), greaterThan(40));
    File('${repo.path}/lib/code.dart').writeAsStringSync('int a = 9;\n');
    expect(await push('run2'), lessThanOrEqualTo(4));
  });

  test(
    'carries edits and new files, holds skip-worktree files at HEAD',
    () async {
      await _git(repo, <String>[
        'update-index',
        '--skip-worktree',
        'lib/secret.dart',
      ]);
      File(
        '${repo.path}/lib/secret.dart',
      ).writeAsStringSync("const String secret = 'REAL-VALUE';\n");
      File('${repo.path}/lib/code.dart').writeAsStringSync('int a = 2;\n');
      File('${repo.path}/lib/new_file.dart').writeAsStringSync('int b = 3;\n');

      final DistSnapshot s = await createDistSnapshot(git, scratchDir: scratch);

      expect(s.isHead, isFalse);
      expect(s.protectedPaths, <String>['lib/secret.dart']);
      expect(
        await _blob(repo, '${s.tree}:lib/secret.dart'),
        await _blob(repo, 'HEAD:lib/secret.dart'),
      );
      expect(
        await _git(repo, <String>['show', '${s.tree}:lib/code.dart']),
        'int a = 2;',
      );
      expect(
        await _git(repo, <String>['show', '${s.tree}:lib/new_file.dart']),
        'int b = 3;',
      );
      expect(
        await _git(repo, <String>['rev-parse', '${s.commit}^']),
        await _blob(repo, 'HEAD'),
      );
      // The real index and HEAD were not touched.
      expect(
        await _git(repo, <String>['status', '--porcelain']),
        contains('lib/code.dart'),
      );
      expect(
        await _git(repo, <String>['ls-files', '-v', 'lib/secret.dart']),
        startsWith('S '),
      );
    },
  );

  test(
    'a skip-worktree file deleted in the working tree stays at HEAD',
    () async {
      await _git(repo, <String>[
        'update-index',
        '--skip-worktree',
        'lib/secret.dart',
      ]);
      File('${repo.path}/lib/secret.dart').deleteSync();
      final DistSnapshot s = await createDistSnapshot(git, scratchDir: scratch);
      expect(
        await _blob(repo, '${s.tree}:lib/secret.dart'),
        await _blob(repo, 'HEAD:lib/secret.dart'),
      );
    },
  );

  test(
    'the verification gate rejects a tree that carries the real value',
    () async {
      // Mutation check of the exclusion: build the tree the naive way (a fresh
      // index + `git add -A`, no exclude) and feed it to the gate.
      await _git(repo, <String>[
        'update-index',
        '--skip-worktree',
        'lib/secret.dart',
      ]);
      File(
        '${repo.path}/lib/secret.dart',
      ).writeAsStringSync("const String secret = 'REAL-VALUE';\n");
      final Map<String, String> env = <String, String>{
        'GIT_INDEX_FILE': '${scratch.path}/naive.index',
      };
      await _git(repo, <String>['read-tree', 'HEAD'], environment: env);
      await _git(repo, <String>['add', '-A'], environment: env);
      final String naiveTree = await _git(repo, <String>[
        'write-tree',
      ], environment: env);
      expect(
        await _git(repo, <String>['show', '$naiveTree:lib/secret.dart']),
        contains('REAL-VALUE'),
        reason: 'precondition: without the exclusion the secret leaks',
      );

      await expectLater(
        verifySnapshotKeepsHeadSecrets(
          git,
          tree: naiveTree,
          protectedPaths: <String>['lib/secret.dart'],
        ),
        throwsA(isA<DistSnapshotError>()),
      );
    },
  );
}
