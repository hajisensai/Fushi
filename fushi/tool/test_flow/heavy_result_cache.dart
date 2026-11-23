// Green results of heavy.dart test / analyze runs, keyed by what they ran on
// (2026-11-22).
//
// The heavy history of 11-15..11-21 had 30 % of the test commands with
// explicit files re-run on the identical file set inside the same agent, and
// 1200+ more re-running files another agent of the same session had already
// run (reviewers re-checking the implementer's green tests), while local runs
// queued twice as long as they ran (86 h queued against 45 h run). A run of
// the same command on the same content cannot come out differently except
// for flakiness, so a green one is remembered and the next identical run
// answers from it at once: no queue, no slot.
//
// The key is the content, not the worktree: the tree object of the working
// tree as it is (tracked + untracked, .gitignore honoured, written through a
// throw-away copy of the index so the real one is never touched), the command
// as resolved (SDK path included), the directory it ran from relative to
// the checkout, and the project variables that gate or point tests at real
// libraries / data (FUSHI_* / SRS_* minus the heavy / dist / bug tooling
// knobs). So two worktrees on the same content share a result.
//
// Only exit 0 is kept (a red run always runs again), only for test / analyze
// kinds and never for a command whose files or machine output the caller
// reads (--coverage, --update-goldens, --file-reporter, a JSON reporter,
// --machine, analyze --write, *_WRITE / *_OUT / preview / shot variables).
// heavy.dart --no-cache, FUSHI_HEAVY_CACHE=off,
// CI and FUSHI_HEAVY=off skip it.
//
// Pure apart from the files and git; unit-tested
// (test/tools/heavy_result_cache_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'heavy_budget.dart';

/// Directory under the heavy state directory holding one file per result.
const String kHeavyResultDir = 'results';

/// How long a green result answers for its content.
const Duration kHeavyResultTtl = Duration(days: 7);

/// How many trailing output lines are kept to repeat on a hit.
const int kHeavyResultTailLines = 15;

/// Arguments whose run writes files or machine output the caller reads: never
/// answered from the cache (a hit only repeats a text tail, so a
/// `--file-reporter json:x` file would be missing or stale, and a JSON
/// reporter's stdout would not be JSON).
const List<String> kHeavyUncacheableArgs = <String>[
  '--coverage',
  '--update-goldens',
  '--update-golden',
  '--merge-coverage',
  '--file-reporter',
  '--machine',
  '--write',
];

/// Environment-variable name prefixes whose variables steer only how heavy /
/// dist / bug tooling runs, never what a test or analyze run concludes: left
/// out of the key so they do not split it.
const List<String> kHeavyKeyIgnoredEnvPrefixes = <String>[
  'FUSHI_HEAVY',
  'FUSHI_DIST_',
  'FUSHI_BUG_',
];

bool _projectEnvName(String name) =>
    name.startsWith('FUSHI_') || name.startsWith('SRS_');

bool _envSet(String? v) {
  if (v == null) return false;
  final String s = v.trim().toLowerCase();
  return s.isNotEmpty && s != '0' && s != 'false' && s != 'off';
}

/// Whether the project variable [name] makes a run write files the caller
/// wants (golden vectors, previews, screenshots, reports): `*_WRITE`,
/// `*_OUT`, preview and shot switches.
bool heavyEnvWritesFiles(String name) =>
    _projectEnvName(name) &&
    (name.endsWith('_WRITE') ||
        name.endsWith('_OUT') ||
        name.contains('_SHOTS') ||
        name.startsWith('FUSHI_PREVIEW') ||
        name.startsWith('FUSHI_SRS_PREVIEW') ||
        name.startsWith('FUSHI_DESIGN_PREVIEW'));

/// The project variables that can change what a run concludes (they gate or
/// point tests at real libraries / data: FUSHI_TEST_FFMPEG, FUSHI_SRS_REAL_DB,
/// FUSHI_FSRS_ID_AUDIT, FUSHI_FLUTTER ...), sorted by name, for the key. A
/// green run without such a switch says nothing about a run with it.
Map<String, String> heavyResultKeyEnvironment(Map<String, String> env) {
  final List<String> names =
      env.keys
          .where(_projectEnvName)
          .where((String n) => !kHeavyKeyIgnoredEnvPrefixes.any(n.startsWith))
          .toList()
        ..sort();
  return <String, String>{for (final String n in names) n: env[n]!};
}

bool _jsonReporter(List<String> argv) {
  for (int i = 0; i < argv.length; i++) {
    final String a = argv[i];
    if (a == '--reporter=json' || a == '-rjson') return true;
    if ((a == '-r' || a == '--reporter') &&
        i + 1 < argv.length &&
        argv[i + 1] == 'json') {
      return true;
    }
  }
  return false;
}

/// Whether a run of [kind] with [argv] may be answered from / stored in the
/// cache, given heavy.dart's own options [own] and [environment].
bool heavyResultCacheable({
  required HeavyKind kind,
  required List<String> argv,
  required List<String> own,
  required Map<String, String> environment,
  required String? leaseSkipReason,
}) {
  if (kind != HeavyKind.test && kind != HeavyKind.analyze) return false;
  if (own.contains('--no-cache')) return false;
  if ((environment['FUSHI_HEAVY_CACHE'] ?? '').toLowerCase() == 'off') {
    return false;
  }
  if (leaseSkipReason == 'CI' || leaseSkipReason == 'FUSHI_HEAVY=off') {
    return false;
  }
  for (final String a in argv) {
    for (final String bad in kHeavyUncacheableArgs) {
      if (a == bad || a.startsWith('$bad=')) return false;
    }
  }
  if (_jsonReporter(argv)) return false;
  for (final MapEntry<String, String> e in environment.entries) {
    if (heavyEnvWritesFiles(e.key) && _envSet(e.value)) return false;
  }
  return true;
}

/// The cache key of [argv] run from [cwdInCheckout] (relative, `/`-separated,
/// '' for the root) on the working tree [tree] with the project variables
/// [environment] (only [heavyResultKeyEnvironment] of it counts).
String heavyResultKey({
  required String tree,
  required List<String> argv,
  required String cwdInCheckout,
  Map<String, String> environment = const <String, String>{},
}) {
  final String raw = jsonEncode(<String, Object>{
    'v': 2,
    'tree': tree,
    'cwd': cwdInCheckout,
    'argv': argv,
    'env': heavyResultKeyEnvironment(environment),
  });
  return sha256.convert(utf8.encode(raw)).toString();
}

/// [cwd] relative to [checkout], `/`-separated; null when outside it.
String? heavyCwdInCheckout(String cwd, String checkout) {
  String norm(String p) {
    String s = p.replaceAll(r'\', '/');
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return Platform.isWindows ? s.toLowerCase() : s;
  }

  final String c = norm(cwd);
  final String root = norm(checkout);
  if (c == root) return '';
  if (!c.startsWith('$root/')) return null;
  // Keep the original casing of the relative part for readability; the
  // comparison above is what decides.
  return cwd
      .replaceAll(r'\', '/')
      .substring(root.length + 1)
      .replaceAll(RegExp(r'/+$'), '');
}

/// One remembered green run.
class HeavyCachedResult {
  const HeavyCachedResult({
    required this.at,
    required this.label,
    required this.ranS,
    required this.where,
    required this.checkout,
    required this.tail,
  });

  final DateTime at;
  final String label;
  final int ranS;

  /// `here` / `elsewhere` (heavy_history.dart's names).
  final String where;
  final String checkout;

  /// The run's last output lines ('' when the output was not captured).
  final String tail;

  Map<String, Object> toJson() => <String, Object>{
    'at': at.toUtc().toIso8601String(),
    'label': label,
    'ranS': ranS,
    'where': where,
    'checkout': checkout,
    'tail': tail,
  };

  static HeavyCachedResult? fromJson(Object? j) {
    if (j is! Map) return null;
    final Object? at = j['at'];
    final Object? label = j['label'];
    final Object? ranS = j['ranS'];
    if (at is! String || label is! String || ranS is! int) return null;
    final DateTime? when = DateTime.tryParse(at);
    if (when == null) return null;
    return HeavyCachedResult(
      at: when,
      label: label,
      ranS: ranS,
      where: (j['where'] as String?) ?? 'here',
      checkout: (j['checkout'] as String?) ?? '',
      tail: (j['tail'] as String?) ?? '',
    );
  }

  /// What heavy.dart prints instead of running the command again.
  String describe(DateTime now) {
    final int ago = now.difference(at).inMinutes;
    final StringBuffer b = StringBuffer();
    if (tail.isNotEmpty) {
      b.writeln('heavy: --- output of the remembered run (last lines) ---');
      b.writeln(tail.trimRight());
      b.writeln('heavy: ---');
    }
    b.write(
      'heavy: CACHED PASS -- `$label` already exited 0 on this exact content '
      '$ago min ago (ran ${ranS}s ${where == 'here' ? 'here' : 'on another machine'}'
      '${checkout.isEmpty ? '' : ', in $checkout'}); not running it again. '
      'Same content + same command cannot differ except for flakiness; '
      'add --no-cache (heavy.dart option, before --) to force a run.',
    );
    return b.toString();
  }
}

File _fileFor(Directory stateDir, String key) =>
    File('${stateDir.path}/$kHeavyResultDir/$key.json');

/// The green result remembered under [key], or null (none, unreadable, or
/// older than [kHeavyResultTtl]). Never throws.
HeavyCachedResult? readHeavyResult(
  Directory stateDir,
  String key, {
  required DateTime now,
}) {
  try {
    final File f = _fileFor(stateDir, key);
    if (!f.existsSync()) return null;
    final HeavyCachedResult? r = HeavyCachedResult.fromJson(
      jsonDecode(f.readAsStringSync()),
    );
    if (r == null || now.difference(r.at) > kHeavyResultTtl) return null;
    return r;
  } on Object {
    return null;
  }
}

/// Remembers [result] under [key] and drops entries past [kHeavyResultTtl].
/// Never throws: a run's result does not depend on the cache.
void writeHeavyResult(
  Directory stateDir,
  String key,
  HeavyCachedResult result, {
  required DateTime now,
}) {
  try {
    final Directory dir = Directory('${stateDir.path}/$kHeavyResultDir')
      ..createSync(recursive: true);
    final File tmp = File('${dir.path}/$key.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode(result.toJson()));
    tmp.renameSync(_fileFor(stateDir, key).path);
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File) continue;
      try {
        if (now.difference(e.statSync().modified) > kHeavyResultTtl) {
          e.deleteSync();
        }
      } on FileSystemException {
        // Another run pruned or replaced it.
      }
    }
  } on Object {
    // Cache only.
  }
}

/// Keeps the last [kHeavyResultTailLines] lines of what passes through.
class HeavyOutputTail {
  final List<int> _bytes = <int>[];
  static const int _keep = 16 * 1024;

  void add(List<int> data) {
    _bytes.addAll(data);
    if (_bytes.length > _keep * 2) {
      _bytes.removeRange(0, _bytes.length - _keep);
    }
  }

  String get text {
    final String s = utf8.decode(_bytes, allowMalformed: true);
    final List<String> lines = const LineSplitter()
        .convert(s)
        .map((String l) => l.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), ''))
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    final int from = lines.length > kHeavyResultTailLines
        ? lines.length - kHeavyResultTailLines
        : 0;
    return lines.sublist(from).join('\n');
  }
}

/// The tree object of [checkout]'s working tree as it is now (tracked and
/// untracked files, .gitignore honoured), or null when git cannot tell.
/// Works on a copy of the index, so the checkout's own index is untouched;
/// the copy keeps the stat cache, so only changed files are hashed.
Future<String?> heavyWorkingTree(
  String checkout, {
  required Directory scratch,
}) async {
  File? copy;
  try {
    final ProcessResult where = await Process.run('git', <String>[
      '-C',
      checkout,
      'rev-parse',
      '--path-format=absolute',
      '--git-path',
      'index',
    ]);
    if (where.exitCode != 0) return null;
    final File index = File((where.stdout as String).trim());
    scratch.createSync(recursive: true);
    copy = File('${scratch.path}/index.$pid');
    if (index.existsSync()) {
      index.copySync(copy.path);
      // Keep the index's own mtime on the copy. git trusts a cached stat only
      // when the entry is older than the index file ("racy git"); a copy
      // stamped "now" would make an entry written in the same second as the
      // real index look settled, so a same-size edit within that second
      // (same mtime second, same size) goes unhashed. File.copySync keeps
      // the mtime on Windows / macOS but not on Linux. setLastModified may
      // round down, which only makes more entries racy (re-hashed): safe.
      copy.setLastModifiedSync(index.lastModifiedSync());
    } else if (copy.existsSync()) {
      copy.deleteSync();
    }
    final Map<String, String> env = <String, String>{
      'GIT_INDEX_FILE': copy.path,
      // Never wait on / take the checkout's own index lock.
      'GIT_OPTIONAL_LOCKS': '0',
    };
    final ProcessResult add = await Process.run('git', <String>[
      '-C',
      checkout,
      'add',
      '-A',
      '--',
      '.',
    ], environment: env);
    if (add.exitCode != 0) return null;
    final ProcessResult tree = await Process.run('git', <String>[
      '-C',
      checkout,
      'write-tree',
    ], environment: env);
    if (tree.exitCode != 0) return null;
    final String sha = (tree.stdout as String).trim();
    return RegExp(r'^[0-9a-f]{40,64}$').hasMatch(sha) ? sha : null;
  } on Object {
    return null;
  } finally {
    try {
      if (copy != null && copy.existsSync()) copy.deleteSync();
    } on Object {
      // Left for the next run to overwrite.
    }
  }
}
