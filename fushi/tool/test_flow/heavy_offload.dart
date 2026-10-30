// Which heavy commands tool/heavy.dart hands to the other machines of the
// dist_test worker config (tool/dist_test.dart --offload / --analyze /
// --build) before it would run them here. Pure decisions, unit-tested
// (test/tools/heavy_offload_test.dart).
//
// Offloaded:
//   - `flutter test` of the app's test/ (run from fushi/) and `flutter test` /
//     `dart test` of a workspace package's test/ (run from packages/<name>/),
//     `--coverage` included (the merged lcov is written here);
//   - `flutter analyze` of the app, run from fushi/;
//   - with heavy.dart's --check-only, a compile check: `flutter build
//     apk|appbundle|windows|macos` from fushi/, `gradlew :app:assemble*` from
//     fushi/android/. Only the build's log and exit code come back, never
//     what it built, so this is for "does it still build", not for an APK or
//     app to use here.
// Everything else (builds whose output is used here, integration test
// launches, `--update-goldens`, sharding / file reporters) stays here.
import 'dart:io';

import 'dist_plan.dart';

enum HeavyOffloadKind { test, analyze, build }

class HeavyOffload {
  const HeavyOffload({required this.kind, required this.distArgs});

  final HeavyOffloadKind kind;

  /// The arguments for tool/dist_test.dart (besides `--config=`).
  final List<String> distArgs;
}

/// How often a busy remote worker is asked again before it is given up on
/// (30 s apart): heavy.dart would rather run here than wait long.
const int kHeavyOffloadBusyRetries = 2;

/// `FUSHI_HEAVY_OFFLOAD=off` keeps every heavy run on this machine.
bool heavyOffloadDisabled(Map<String, String> env) =>
    (env['FUSHI_HEAVY_OFFLOAD'] ?? '').toLowerCase() == 'off';

/// The worker config to offload with: `FUSHI_DIST_CONFIG`, else
/// tool/dist_test/workers.local.json under [appDir] (dist_test's default).
/// Null when neither exists.
String? heavyOffloadConfig(
  Map<String, String> env,
  String appDir, {
  bool Function(String path)? exists,
}) {
  final bool Function(String) isFile =
      exists ?? (String p) => File(p).existsSync();
  final String? fromEnv = env['FUSHI_DIST_CONFIG'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return isFile(fromEnv) ? fromEnv : null;
  }
  final String local = '$appDir/tool/dist_test/workers.local.json';
  return isFile(local) ? local : null;
}

/// Where [cwd] sits in the checkout at [root], `/`-separated (`fushi`,
/// `fushi/android`, `packages/<name>`; empty for the root itself), or null
/// outside it. Windows paths compare case-insensitively.
String? heavyOffloadWhere(String cwd, String root) {
  String norm(String p) {
    String s = p.replaceAll(r'\', '/');
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  final String c = norm(cwd);
  final String r = norm(root);
  final bool windows = RegExp(r'^[A-Za-z]:').hasMatch(r);
  final String cc = windows ? c.toLowerCase() : c;
  final String rr = windows ? r.toLowerCase() : r;
  if (cc == rr) return '';
  if (!cc.startsWith('$rr/')) return null;
  return c.substring(r.length + 1);
}

/// `flutter test` options that only make sense here: they write files on this
/// machine (other than the coverage dist_test merges back), or shard / report
/// in their own way.
const Set<String> _localOnlyTestOptions = <String>{
  '--update-goldens',
  '--merge-coverage',
  '--file-reporter',
  '--total-shards',
  '--shard-index',
  '--start-paused',
  '--debug-logs',
};

/// `flutter test` options that take a value as the next argument, by their
/// long name (short forms map onto these).
const Map<String, String> _testValueOptions = <String, String>{
  '--name': '--name',
  '-n': '--name',
  '--plain-name': '--plain-name',
  '--tags': '--tags',
  '-t': '--tags',
  '--exclude-tags': '--exclude-tags',
  '-x': '--exclude-tags',
  '--timeout': '--timeout',
  '--test-randomize-ordering-seed': '--test-randomize-ordering-seed',
};

/// What dist_test takes care of itself: dropped from the command.
bool _droppedTestOption(String a) =>
    a == '--no-pub' ||
    a.startsWith('--concurrency=') ||
    a.startsWith('-j') ||
    a.startsWith('--reporter=') ||
    a.startsWith('-r');

/// A value the shim passes on unchanged (worker_shim.sh check_flutter_arg).
final RegExp _plainValue = RegExp(r'^[A-Za-z0-9_,.:+][A-Za-z0-9_,.:+-]*$');
final RegExp _plainFlag = RegExp(r'^--[a-z][a-z-]*$');

/// [command] (resolved: the executable first) as an offload, or null when it
/// runs here. [where]: the directory it runs in, relative to the checkout
/// root ([heavyOffloadWhere]); [cwd]: the same, absolute (coverage lands
/// under it). [checkOnly]: heavy.dart --check-only, so a build's output is
/// not wanted here. [exists]: the path exists relative to [cwd].
HeavyOffload? planHeavyOffload(
  List<String> command, {
  required String where,
  required String cwd,
  required bool checkOnly,
  required bool Function(String path) exists,
}) {
  if (command.length < 2) return null;
  final String exe = _base(command.first);
  final bool flutter = exe == 'flutter';
  if (checkOnly &&
      ((where == kDistAppPackage && flutter && command[1] == 'build') ||
          (where == '$kDistAppPackage/android' && exe == 'gradlew'))) {
    final DistBuild? build = distBuildOf(command);
    if (build == null) return null;
    return HeavyOffload(
      kind: HeavyOffloadKind.build,
      distArgs: <String>[
        '--build',
        '--',
        if (build.tool == 'flutter') ...<String>['flutter', 'build'],
        if (build.tool == 'gradle') 'gradlew',
        ...build.args,
      ],
    );
  }
  if (!isDistPackageDir(where)) return null;
  final List<String> rest = command.sublist(2);
  if (where == kDistAppPackage) {
    if (!flutter) return null;
    return switch (command[1]) {
      'test' => _planTest(rest, exists, package: where, cwd: cwd, dart: false),
      'analyze' => _planAnalyze(rest, exists),
      _ => null,
    };
  }
  if ((!flutter && exe != 'dart') || command[1] != 'test') return null;
  return _planTest(rest, exists, package: where, cwd: cwd, dart: !flutter);
}

/// `flutter.bat` / `C:\...\dart.exe` → `flutter` / `dart`.
String _base(String executable) {
  final String name = executable
      .replaceAll(r'\', '/')
      .split('/')
      .last
      .toLowerCase();
  for (final String ext in <String>['.bat', '.exe', '.cmd']) {
    if (name.endsWith(ext)) return name.substring(0, name.length - ext.length);
  }
  return name;
}

bool _absolute(String p) =>
    p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);

HeavyOffload? _planTest(
  List<String> args,
  bool Function(String) exists, {
  required String package,
  required String cwd,
  required bool dart,
}) {
  final List<String> options = <String>[];
  final List<String> paths = <String>[];
  bool coverage = false;
  String? coveragePath;
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (a == '-j' || a == '--concurrency' || a == '-r' || a == '--reporter') {
      i++; // the dropped option's value
      continue;
    }
    if (_droppedTestOption(a)) continue;
    if (a.startsWith('-')) {
      final int eq = a.indexOf('=');
      final String name = eq < 0 ? a : a.substring(0, eq);
      if (_localOnlyTestOptions.contains(name)) return null;
      // `dart test --coverage=<dir>` writes VM json, not lcov: stays here.
      if (name == '--coverage' || name == '--coverage-path') {
        if (dart) return null;
        if (name == '--coverage') {
          if (eq >= 0) return null;
          coverage = true;
        } else {
          coveragePath = eq >= 0
              ? a.substring(eq + 1)
              : (i + 1 < args.length ? args[++i] : null);
          if (coveragePath == null || coveragePath.isEmpty) return null;
        }
        continue;
      }
      final String? long = _testValueOptions[name];
      if (long != null) {
        final String? value = eq >= 0
            ? a.substring(eq + 1)
            : (i + 1 < args.length ? args[++i] : null);
        if (value == null || !_plainValue.hasMatch(value)) return null;
        // `--name=value`: dist_test would take a bare value that starts with
        // `test` for a path.
        options.add('$long=$value');
        continue;
      }
      if (eq >= 0 || !_plainFlag.hasMatch(a)) return null;
      options.add(a);
      continue;
    }
    final String? path = _testPath(a, exists);
    if (path == null) return null;
    paths.add(path);
  }
  final String base = cwd.replaceAll(r'\', '/');
  final String? lcov = !coverage
      ? null
      : coveragePath == null
      ? '$base/coverage/lcov.info'
      : _absolute(coveragePath)
      ? coveragePath.replaceAll(r'\', '/')
      : '$base/${coveragePath.replaceAll(r'\', '/')}';
  return HeavyOffload(
    kind: HeavyOffloadKind.test,
    distArgs: <String>[
      '--offload',
      '--busy-retries=$kHeavyOffloadBusyRetries',
      if (package != kDistAppPackage) '--package=$package',
      if (lcov != null) ...<String>['--coverage', '--coverage-out=$lcov'],
      ...options,
      ...paths,
    ],
  );
}

/// A suite file or directory under test/ dist_test can ship, normalized.
String? _testPath(String raw, bool Function(String) exists) {
  String p = raw.replaceAll(r'\', '/');
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  if (p.endsWith('/')) p = p.substring(0, p.length - 1);
  if (p != 'test' && !p.startsWith('test/')) return null;
  if (p.split('/').contains('..')) return null;
  if (!RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(p)) return null;
  if (p.endsWith('.dart') && !isSafeDistTestPath(p)) return null;
  return exists(p) ? p : null;
}

HeavyOffload? _planAnalyze(List<String> args, bool Function(String) exists) {
  final List<String> options = <String>[];
  final List<String> paths = <String>[];
  for (final String a in args) {
    if (a == '--no-pub') continue;
    if (kDistAnalyzeOptions.contains(a)) {
      options.add(a);
      continue;
    }
    if (a.startsWith('-')) return null;
    String p = a.replaceAll(r'\', '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    if (!isSafeDistAnalyzePath(p) || !exists(p)) return null;
    paths.add(p);
  }
  return HeavyOffload(
    kind: HeavyOffloadKind.analyze,
    distArgs: <String>['--analyze', ...paths, ...options],
  );
}
