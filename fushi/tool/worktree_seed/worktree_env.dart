// Shared lookups for the worktree_seed tool: sibling worktrees and the
// machine-wide cache root. Tests: test/tools/worktree_seed_hook_downloads_test.dart.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Machine-wide cache root shared by every worktree on this machine:
/// `%LOCALAPPDATA%/fushi-heavy` on Windows, else `$XDG_CACHE_HOME/fushi-heavy`
/// or `~/.cache/fushi-heavy`. `FUSHI_SEED_CACHE` overrides it (tests, CI).
/// Null when none of these is set.
String? seedCacheRoot(Map<String, String> env) {
  final String? override = env['FUSHI_SEED_CACHE'];
  if (override != null && override.isNotEmpty) return override;
  final String? local = env['LOCALAPPDATA'];
  if (local != null && local.isNotEmpty) return p.join(local, 'fushi-heavy');
  final String? xdg = env['XDG_CACHE_HOME'];
  if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'fushi-heavy');
  final String? home = env['HOME'];
  if (home != null && home.isNotEmpty) {
    return p.join(home, '.cache', 'fushi-heavy');
  }
  return null;
}

/// Worktree roots listed by `git worktree list --porcelain` output [porcelain],
/// in git's order (main checkout first).
List<String> parseWorktreeList(String porcelain) => <String>[
  for (final String line in porcelain.split('\n'))
    if (line.startsWith('worktree ')) line.substring('worktree '.length).trim(),
];

/// Every worktree of the repository at [repoRoot] (including itself).
List<String> listWorktrees(String repoRoot) {
  final ProcessResult r = Process.runSync('git', <String>[
    '-C',
    repoRoot,
    'worktree',
    'list',
    '--porcelain',
  ]);
  if (r.exitCode != 0) {
    throw StateError('git worktree list failed: ${r.stderr}');
  }
  return parseWorktreeList(r.stdout as String);
}

/// The top level of the git worktree containing [dir].
String gitTopLevel(String dir) {
  final ProcessResult r = Process.runSync('git', <String>[
    '-C',
    dir,
    'rev-parse',
    '--show-toplevel',
  ]);
  if (r.exitCode != 0) {
    throw StateError('not inside a git worktree: $dir');
  }
  return (r.stdout as String).trim();
}

/// Whether paths [a] and [b] name the same directory (case-insensitive on
/// Windows, `/` and `\` equal).
bool samePath(String a, String b) {
  String norm(String s) {
    final String n = p.normalize(p.absolute(s)).replaceAll(r'\', '/');
    return Platform.isWindows ? n.toLowerCase() : n;
  }

  return norm(a) == norm(b);
}
