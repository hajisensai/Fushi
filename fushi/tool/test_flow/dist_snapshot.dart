/// The commit a `tool/dist_test.dart` run ships to its workers: HEAD plus the
/// working tree's uncommitted changes, minus the real secret values.
///
/// Built through a throw-away index (`GIT_INDEX_FILE`), so the real index, the
/// stash stack (shared by every worktree) and HEAD are never touched.
///
/// The secret rule (docs/specs/2026-10-24-distributed-unit-tests.md §1): the
/// skip-worktree files (`tool/setup_worktree.ps1` copies the real OAuth / log
/// upload secrets into them) carry no skip-worktree bit in a fresh index, so
/// a plain `git add -A` would put the real values into the snapshot and push
/// them to another machine. They are excluded from the add, and the finished
/// tree is checked blob by blob against HEAD before anything leaves the box.
library;

import 'dart:io';

/// A finished snapshot.
class DistSnapshot {
  const DistSnapshot({
    required this.commit,
    required this.base,
    required this.tree,
    required this.isHead,
    required this.protectedPaths,
  });

  final String commit;

  /// HEAD: [commit] itself, or its parent.
  final String base;

  final String tree;

  /// True when the working tree had no change: [commit] is HEAD itself.
  final bool isHead;

  /// The skip-worktree paths that were held at their HEAD content.
  final List<String> protectedPaths;
}

class DistSnapshotError implements Exception {
  DistSnapshotError(this.message);
  final String message;
  @override
  String toString() => 'DistSnapshotError: $message';
}

typedef GitRunner =
    Future<ProcessResult> Function(
      List<String> args, {
      Map<String, String>? environment,
    });

/// `git` in [repoRoot] (top level of the checkout).
GitRunner gitIn(String repoRoot) =>
    (List<String> args, {Map<String, String>? environment}) => Process.run(
      'git',
      args,
      workingDirectory: repoRoot,
      environment: environment,
    );

Future<String> _git(
  GitRunner git,
  List<String> args, {
  Map<String, String>? environment,
}) async {
  final ProcessResult r = await git(args, environment: environment);
  if (r.exitCode != 0) {
    throw DistSnapshotError(
      'git ${args.join(' ')} failed (${r.exitCode}): '
      '${(r.stderr as String).trim()}',
    );
  }
  return (r.stdout as String).trim();
}

/// Paths (repo-relative, `/`-separated) whose index entry has the
/// skip-worktree bit (`git ls-files -v` tag `S`).
Future<List<String>> skipWorktreePaths(GitRunner git) async {
  final String out = await _git(git, <String>['ls-files', '-v']);
  return <String>[
    for (final String line in out.split('\n'))
      if (line.startsWith('S ')) line.substring(2).trim(),
  ]..sort();
}

/// Builds the snapshot. [scratchDir] holds the temporary index and is left
/// to the caller to delete.
Future<DistSnapshot> createDistSnapshot(
  GitRunner git, {
  required Directory scratchDir,
}) async {
  final List<String> protectedPaths = await skipWorktreePaths(git);
  final String head = await _git(git, <String>['rev-parse', 'HEAD']);
  final String headTree = await _git(git, <String>['rev-parse', 'HEAD^{tree}']);

  final Map<String, String> env = <String, String>{
    'GIT_INDEX_FILE': '${scratchDir.absolute.path}/dist.index',
  };
  await _git(git, <String>['read-tree', 'HEAD'], environment: env);
  await _git(git, <String>[
    'add',
    '-A',
    '--',
    ':/',
    for (final String path in protectedPaths) ':(top,exclude,literal)$path',
  ], environment: env);
  final String tree = await _git(git, <String>['write-tree'], environment: env);

  await verifySnapshotKeepsHeadSecrets(
    git,
    tree: tree,
    protectedPaths: protectedPaths,
  );

  if (tree == headTree) {
    return DistSnapshot(
      commit: head,
      base: head,
      tree: tree,
      isHead: true,
      protectedPaths: protectedPaths,
    );
  }
  final String commit = await _git(
    git,
    <String>['commit-tree', tree, '-p', head, '-m', 'dist_test snapshot'],
    environment: <String, String>{
      // Fixed identity: the snapshot never lands on a branch, and a missing
      // user.email must not abort a test run.
      'GIT_AUTHOR_NAME': 'dist_test',
      'GIT_AUTHOR_EMAIL': 'dist_test@localhost',
      'GIT_COMMITTER_NAME': 'dist_test',
      'GIT_COMMITTER_EMAIL': 'dist_test@localhost',
    },
  );
  return DistSnapshot(
    commit: commit,
    base: head,
    tree: tree,
    isHead: false,
    protectedPaths: protectedPaths,
  );
}

/// Throws unless every [protectedPaths] entry has the same blob (or the same
/// absence) in [tree] as in HEAD. The last gate before a push.
Future<void> verifySnapshotKeepsHeadSecrets(
  GitRunner git, {
  required String tree,
  required List<String> protectedPaths,
}) async {
  for (final String path in protectedPaths) {
    final ProcessResult inHead = await git(<String>[
      'rev-parse',
      '--verify',
      '--quiet',
      'HEAD:$path',
    ]);
    final ProcessResult inTree = await git(<String>[
      'rev-parse',
      '--verify',
      '--quiet',
      '$tree:$path',
    ]);
    final String headBlob = inHead.exitCode == 0
        ? (inHead.stdout as String).trim()
        : '';
    final String treeBlob = inTree.exitCode == 0
        ? (inTree.stdout as String).trim()
        : '';
    if (headBlob != treeBlob) {
      throw DistSnapshotError(
        'snapshot tree $tree carries a working-tree version of the '
        'skip-worktree file $path (HEAD blob "$headBlob", snapshot blob '
        '"$treeBlob"); refusing to ship a real secret to another machine',
      );
    }
  }
}
