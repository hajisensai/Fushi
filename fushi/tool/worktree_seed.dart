// Warm a fresh worktree with machine-shareable build state, called by
// tool/setup_worktree.ps1 after bootstrap. See docs/agent/build.md
// 「新 worktree 第一次 flutter test」.
//
//   dart fushi/tool/worktree_seed.dart hooks [--repo <worktree root>]
//     Copy verified native-asset hook downloads (pdfium, sqlite3) from the
//     machine cache / sibling worktrees (worktree_seed/hook_downloads.dart).
//
//   dart fushi/tool/worktree_seed.dart kernel [--repo <root>] [--no-generate]
//     Put the machine-wide third-party compile seed into
//     fushi/build/test_cache/build/ (worktree_seed/test_kernel_seed.dart). On
//     a cache miss, generate it here with one real `flutter test` of a
//     generated entry (through tool/heavy.dart, kept on this machine) and
//     store it for the next worktree; --no-generate only restores.
//
// Exit codes: 0 done (including "nothing to do", with the reason printed),
// 1 seed generation failed or produced an unusable seed, 64 usage error.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'worktree_seed/hook_downloads.dart';
import 'worktree_seed/test_kernel_seed.dart';
import 'worktree_seed/worktree_env.dart';

const String _usage =
    'usage: dart fushi/tool/worktree_seed.dart hooks|kernel '
    '[--repo <worktree root>] [--no-generate]';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  final String command = args.first;
  String? repo;
  bool generate = true;
  for (int i = 1; i < args.length; i++) {
    if (args[i] == '--repo' && i + 1 < args.length) {
      repo = args[++i];
    } else if (args[i] == '--no-generate' && command == 'kernel') {
      generate = false;
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
    case 'kernel':
      exitCode = await _runKernel(root, generate: generate);
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

Future<int> _runKernel(String root, {required bool generate}) async {
  final String app = p.join(root, 'fushi');
  final String testCache = p.join(app, kTestCacheRel);
  if (listSeedDills(testCache).isNotEmpty) {
    stdout.writeln('test kernel seed: worktree already has a compile cache');
    return 0;
  }
  final List<String> why = <String>[];
  final SeedKeyInputs? inputs = readSeedKeyInputs(root, why);
  final String? cacheBase = seedCacheRoot(Platform.environment);
  if (inputs == null || cacheBase == null) {
    final String reason = inputs == null
        ? why.join('; ')
        : 'no machine cache directory';
    stdout.writeln('test kernel seed: skipped ($reason)');
    return 0;
  }
  final String keyDir = p.join(cacheBase, 'test-seed', seedKey(inputs));
  final List<String> restored = restoreSeed(keyDir, testCache);
  if (restored.isNotEmpty) {
    stdout.writeln(
      'test kernel seed: copied ${restored.join(', ')} from $keyDir',
    );
    return 0;
  }
  if (!generate) {
    stdout.writeln('test kernel seed: none cached at $keyDir (--no-generate)');
    return 0;
  }
  if (!takeSeedLock(keyDir)) {
    stdout.writeln(
      'test kernel seed: another setup is generating $keyDir; '
      'this worktree compiles cold',
    );
    return 0;
  }
  try {
    return await _generate(root, app, testCache, keyDir);
  } finally {
    releaseSeedLock(keyDir);
  }
}

Future<int> _generate(
  String root,
  String app,
  String testCache,
  String keyDir,
) async {
  final List<SeedPackage> packages = readPackageConfig(
    p.join(root, '.dart_tool', 'package_config.json'),
  );
  final Map<String, SeedPackage> seedable = seedablePackages(packages, root);
  final List<String> libs = scanSeedLibraries(seedScanDirs(root), seedable);
  final File entry = File(p.join(app, kTestSeedEntryRel));
  entry.parent.createSync(recursive: true);
  entry.writeAsStringSync(renderSeedEntry(libs));
  stdout.writeln(
    'test kernel seed: generating $keyDir from ${libs.length} third-party '
    'libraries (one flutter test through tool/heavy.dart)',
  );
  final Process proc = await Process.start(
    Platform.resolvedExecutable,
    <String>[
      'tool/heavy.dart',
      '--',
      'flutter',
      'test',
      kTestSeedEntryRel,
      '--no-pub',
    ],
    workingDirectory: app,
    // The seed must be compiled on this machine: an offloaded run leaves its
    // compile cache on the other one. (heavy only offloads test/ paths; this
    // keeps it that way if that rule widens.)
    environment: <String, String>{'FUSHI_HEAVY_OFFLOAD': 'off'},
    mode: ProcessStartMode.inheritStdio,
  );
  final int code = await proc.exitCode;
  entry.parent.deleteSync(recursive: true);
  if (code != 0) {
    stdout.writeln('test kernel seed: flutter test exited $code; not stored');
    return 1;
  }
  final List<File> dills = listSeedDills(testCache);
  if (dills.isEmpty) {
    stdout.writeln('test kernel seed: flutter test wrote no compile cache');
    return 1;
  }
  for (final File dill in dills) {
    final List<String> leaked = worktreePathsInDill(dill.path, root);
    if (leaked.isNotEmpty) {
      stdout.writeln(
        'test kernel seed: ${p.basename(dill.path)} records worktree paths, '
        'so any other worktree would discard it; not stored:\n  '
        '${leaked.take(10).join('\n  ')}',
      );
      return 1;
    }
  }
  final List<String> stored = storeSeed(testCache, keyDir);
  stdout.writeln('test kernel seed: stored ${stored.join(', ')} in $keyDir');
  return 0;
}
