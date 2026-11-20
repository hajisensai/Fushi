// Warm a fresh worktree with machine-shareable build state, called by
// tool/setup_worktree.ps1 after bootstrap. See docs/agent/build.md
// 「新 worktree 第一次 flutter test」.
//
//   dart fushi/tool/worktree_seed.dart hooks [--repo <worktree root>]
//     Copy verified native-asset hook downloads (pdfium, sqlite3) from the
//     machine cache / sibling worktrees (worktree_seed/hook_downloads.dart).
//
// Exit codes: 0 done (including "nothing to copy"), 64 usage error.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'worktree_seed/hook_downloads.dart';
import 'worktree_seed/worktree_env.dart';

const String _usage =
    'usage: dart fushi/tool/worktree_seed.dart hooks [--repo <worktree root>]';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  final String command = args.first;
  String? repo;
  for (int i = 1; i < args.length; i++) {
    if (args[i] == '--repo' && i + 1 < args.length) {
      repo = args[++i];
    } else {
      stderr.writeln('unknown argument: ${args[i]}\n$_usage');
      exitCode = 64;
      return;
    }
  }
  final String root = repo ?? gitTopLevel(Directory.current.path);
  switch (command) {
    case 'hooks':
      _runHooks(root);
    default:
      stderr.writeln('unknown command: $command\n$_usage');
      exitCode = 64;
  }
}

void _runHooks(String root) {
  final String? cacheBase = seedCacheRoot(Platform.environment);
  final String? cacheRoot = cacheBase == null
      ? null
      : p.join(cacheBase, 'hook-downloads');
  final List<String> siblings = <String>[
    for (final String wt in listWorktrees(root))
      if (!samePath(wt, root)) hookSharedRoot(wt),
  ];
  final HookSeedReport r = seedHookDownloads(
    targetShared: hookSharedRoot(root),
    sourceShared: siblings,
    cacheRoot: cacheRoot,
  );
  for (final MapEntry<String, String> e in r.copied.entries) {
    stdout.writeln('  copied ${e.key}  <- ${e.value}');
  }
  for (final MapEntry<String, String> e in r.rejected.entries) {
    stdout.writeln('  skipped ${e.key}: ${e.value}');
  }
  stdout.writeln(
    'hook downloads: ${r.copied.length} copied, ${r.present.length} already '
    'present, ${r.rejected.length} skipped, ${r.cached.length} stored in '
    '${cacheRoot ?? "(no machine cache)"}',
  );
}
