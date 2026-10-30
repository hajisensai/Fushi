// Which heavy commands tool/heavy.dart hands to the other machines of the
// dist_test worker config (tool/dist_test.dart --offload / --analyze) before
// it would run them here. Pure decisions, unit-tested
// (test/tools/heavy_offload_test.dart).
//
// Offloaded: `flutter test` of suites under test/ and `flutter analyze` of the
// app, both run from fushi/. Everything else (builds, gradle, integration
// test launches, other packages' tests) produces something this machine has
// to use itself, or needs its screen, and stays here.
import 'dart:io';

import 'dist_plan.dart';

enum HeavyOffloadKind { test, analyze }

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

/// `flutter test` options that only make sense here: they write files on this
/// machine, or shard / report in their own way.
const Set<String> _localOnlyTestOptions = <String>{
  '--update-goldens',
  '--coverage',
  '--merge-coverage',
  '--coverage-path',
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

/// [command] (resolved: the flutter executable first) as an offload, or null
/// when it runs here. [inAppDir]: the command runs from fushi/ (where
/// dist_test works). [exists]: the path exists relative to that directory.
HeavyOffload? planHeavyOffload(
  List<String> command, {
  required bool inAppDir,
  required bool Function(String path) exists,
}) {
  if (!inAppDir || command.length < 2) return null;
  final String exe = command.first
      .replaceAll(r'\', '/')
      .split('/')
      .last
      .toLowerCase();
  if (exe != 'flutter' && exe != 'flutter.bat') return null;
  final List<String> rest = command.sublist(2);
  return switch (command[1]) {
    'test' => _planTest(rest, exists),
    'analyze' => _planAnalyze(rest, exists),
    _ => null,
  };
}

HeavyOffload? _planTest(List<String> args, bool Function(String) exists) {
  final List<String> options = <String>[];
  final List<String> paths = <String>[];
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
  return HeavyOffload(
    kind: HeavyOffloadKind.test,
    distArgs: <String>[
      '--offload',
      '--busy-retries=$kHeavyOffloadBusyRetries',
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
