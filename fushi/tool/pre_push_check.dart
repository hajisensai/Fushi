// Pre-push check: the parts of CI a local run can reproduce cheaply, in one
// command, so that "it passed locally" means "CI will not turn red on it".
//
//   dart run tool/pre_push_check.dart [--base=<ref>] [--list] [--skip-analyze]
//                                     [--allow-flutter-mismatch]
//                                     [--files <paths...> | --files-from=<list>]
//
// Why (upstream 2026-09-20..30): agents ran `flutter analyze` + hand-picked tests
// before pushing, yet CI went red. analyze failed once in 10 days; of the 36 PRs
// whose CI caught a regression they introduced, 15 were red only on source-scan
// guards and 3 on guards plus other tests. Those guards name the files they
// scan by path literal (tool/tests_for_changes.dart derives them), or scan whole
// trees (the enumeration batch in docs/agent/fast-workflow.md, which the rules
// only ran AFTER merging). This tool runs, in order:
//   0. toolchain: the local Flutter must be the version CI pins (main.yml);
//   1. full `flutter analyze` in fushi/ (analyzing only changed files misses
//      callers broken by an API change), plus `dart analyze` of the pure-Dart
//      packages CI analyzes separately when they changed;
//   2. app tests: the enumeration guard batch + path-literal-triggered tests
//      (tests_for_changes, Dart trees included) + tests importing a changed
//      library / helper + changed test files;
//   3. tests of changed packages (as main.yml's package loop / server-gate);
//   4. the JS suites when JS / assets / the extension changed.
// Every Flutter test batch is judged by exit code AND executed count (BUG-1157).
// The full sharded suite still runs on CI; this is the cheap, high-yield subset.
import 'dart:convert';
import 'dart:io';

import 'test_flow/flutter_test_failure_filter.dart';
import 'test_flow/pre_push_selection.dart';
import 'tests_for_changes.dart'
    show
        RepoFs,
        buildReferenceIndex,
        listAppTestFiles,
        locateRepoRoot,
        normalizeChangedPath,
        selectTestsForChanges;

class _Step {
  _Step(this.name, this.ok, this.detail, this.elapsed);
  final String name;
  final bool ok;
  final String detail;
  final Duration elapsed;
}

Future<void> main(List<String> args) async {
  final RepoFs fs = RepoFs(locateRepoRoot(Directory.current));
  final String root = fs.root.path;
  final bool listOnly = args.contains('--list');
  final bool skipAnalyze = args.contains('--skip-analyze');
  final bool allowMismatch = args.contains('--allow-flutter-mismatch');
  String? base;
  List<String>? explicitFiles;
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (a.startsWith('--base=')) base = a.substring('--base='.length);
    if (a.startsWith('--files-from=')) {
      // One path per line; for change sets too long for a command line.
      explicitFiles = File(a.substring('--files-from='.length))
          .readAsLinesSync()
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
    }
    if (a == '--files') {
      explicitFiles = args.sublist(i + 1);
      break;
    }
  }

  // ---- changed files ------------------------------------------------------
  final List<String> changed = (explicitFiles ?? _changedFromGit(root, base))
      .map((String raw) => normalizeChangedPath(raw, fs))
      .toSet()
      .toList()
    ..sort();
  if (changed.isEmpty) {
    stdout.writeln(
        'pre-push: no changed files against the merge base; nothing to check.');
    return;
  }

  // ---- selection ----------------------------------------------------------
  final Map<String, String> testSources = <String, String>{
    for (final String t in listAppTestFiles(fs))
      t: File('$root/$t').readAsStringSync(),
  };
  final String fastWorkflow =
      File('$root/docs/agent/fast-workflow.md').readAsStringSync();
  final List<String> guards = parseEnumerationGuards(fastWorkflow)
      .map((String t) => 'fushi/$t')
      .where(testSources.containsKey)
      .toList();
  if (guards.length < 40) {
    _fail('enumeration guard list in docs/agent/fast-workflow.md parsed to '
        '${guards.length} entries (expected ~50): the table format changed?');
  }
  final Map<String, Set<String>> byPath = selectTestsForChanges(
    changedFiles: changed,
    index: buildReferenceIndex(fs),
    fs: fs,
    includeDartTrees: true,
  );
  final Map<String, String> packageNames = _packageNames(root);
  final Set<String> importKeys = <String>{
    for (final String c in changed)
      ...importKeysForChange(
        c,
        packageNames: packageNames,
        partOwner: File('$root/$c').existsSync() && c.endsWith('.dart')
            ? partOfTarget(File('$root/$c').readAsStringSync())
            : null,
      ),
  };
  final Set<String> byImport = directImpactTests(
    changed: changed,
    testSources: testSources,
    importKeys: importKeys,
  );
  final bool runBatch = touchesDartTrees(changed);
  final List<String> appTests = <String>{
    if (runBatch) ...guards,
    ...byPath.keys.where(testSources.containsKey),
    ...byImport,
  }.toList()
    ..sort();
  final List<String> packages = changedTestablePackages(changed)
      .where((String p) => Directory('$root/packages/$p/test').existsSync())
      .toList()
    ..sort();
  final List<String> analyzePackages = changedTestablePackages(changed)
      .where(kSeparatelyAnalyzedPackages.contains)
      .toList()
    ..sort();
  final bool js = touchesJsSuites(changed);

  stdout
    ..writeln('pre-push: ${changed.length} changed file(s)')
    ..writeln('  app tests: ${appTests.length} = '
        '${runBatch ? '${guards.length} enumeration guards' : 'no enumeration batch (no Dart tree changed)'}'
        ' + ${byPath.length} path-literal + ${byImport.length} import-impact '
        '(deduplicated)')
    ..writeln(
        '  package tests: ${packages.isEmpty ? '-' : packages.join(', ')}')
    ..writeln('  separate dart analyze: '
        '${analyzePackages.isEmpty ? '-' : analyzePackages.join(', ')}')
    ..writeln('  JS suites: ${js ? 'yes' : 'no'}');
  if (listOnly) {
    for (final String t in appTests) {
      final List<String> why = <String>[
        if (runBatch && guards.contains(t)) 'batch',
        if (byPath.containsKey(t)) 'path',
        if (byImport.contains(t)) 'import',
      ];
      stdout.writeln('  $t  [${why.join(',')}]');
    }
    return;
  }

  // ---- run ----------------------------------------------------------------
  final String flutter = _flutterExecutable();
  final String dart = Platform.resolvedExecutable;
  final List<_Step> steps = <_Step>[];

  steps.add(await _timed('toolchain', () async {
    final String? ci = _ciFlutterVersion(root);
    final String? local = _localFlutterVersion(flutter);
    if (ci == null || local == null) {
      return (false, 'could not read versions (CI: $ci, local: $local)');
    }
    if (ci != local && !allowMismatch) {
      return (
        false,
        'local Flutter $local != CI $ci: analyzer / lints differ between them. '
            'Run this tool with the $ci SDK\'s dart (it uses the flutter next to it).',
      );
    }
    return (true, 'Flutter $local (CI $ci)');
  }));
  if (!steps.last.ok) return _report(steps);

  // Analyze and tests are independent: run the two lanes concurrently so the
  // wall time is the longer lane, not the sum (first measurement, sequential:
  // analyze 135 s + 69 test files 218 s).
  final Future<List<_Step>> analyzeLane = () async {
    final List<_Step> out = <_Step>[];
    if (skipAnalyze) return out;
    out.add(await _timed('flutter analyze (fushi/)', () async {
      // --no-pub: the worktree is bootstrapped; resolving the whole workspace
      // again on every run only costs time.
      final int code = await _stream(
          flutter, <String>['analyze', '--no-pub'], '$root/fushi');
      return (code == 0, 'exit $code');
    }));
    for (final String p in analyzePackages) {
      out.add(await _timed('dart analyze (packages/$p)', () async {
        final int code =
            await _stream(dart, <String>['analyze'], '$root/packages/$p');
        return (code == 0, 'exit $code');
      }));
    }
    return out;
  }();

  final Future<List<_Step>> testLane = () async {
    final List<_Step> out = <_Step>[];
    final List<List<String>> batches = chunkByCommandLength(
      appTests.map((String t) => t.substring('fushi/'.length)).toList(),
    );
    for (int i = 0; i < batches.length; i++) {
      out.add(await _timed(
        'app tests ${i + 1}/${batches.length} (${batches[i].length} files)',
        () => _flutterTests(flutter, '$root/fushi', batches[i],
            '$root/.codex-test/pre-push/app-$i'),
      ));
    }
    for (final String p in packages) {
      out.add(await _timed(
          'package tests (packages/$p)',
          () => _flutterTests(
                flutter,
                '$root/packages/$p',
                const <String>[],
                '$root/.codex-test/pre-push/pkg-$p',
              )));
    }
    if (js) {
      out.add(await _timed('JS behavior tests (test/js)', () async {
        if (!Directory('$root/test/js/node_modules').existsSync()) {
          final int install =
              await _stream('npm', <String>['install'], '$root/test/js');
          if (install != 0) return (false, 'npm install exit $install');
        }
        final int code =
            await _stream('npm', <String>['test'], '$root/test/js');
        return (code == 0, 'exit $code');
      }));
      out.add(await _timed('browser-extension JS tests', () async {
        final List<String> files = Directory('$root/tools/browser-extension')
            .listSync()
            .whereType<File>()
            .map((File f) => f.uri.pathSegments.last)
            .where((String n) => n.endsWith('.test.js'))
            .toList()
          ..sort();
        final int code = await _stream('node', <String>['--test', ...files],
            '$root/tools/browser-extension');
        return (code == 0, 'exit $code, ${files.length} files');
      }));
    }
    return out;
  }();

  final List<List<_Step>> lanes =
      await Future.wait(<Future<List<_Step>>>[analyzeLane, testLane]);
  steps
    ..addAll(lanes[0])
    ..addAll(lanes[1]);
  _report(steps);
}

Future<_Step> _timed(
    String name, Future<(bool, String)> Function() body) async {
  stdout.writeln('\n== $name');
  final Stopwatch sw = Stopwatch()..start();
  final (bool ok, String detail) = await body();
  sw.stop();
  stdout.writeln(
      '   -> ${ok ? 'OK' : 'FAILED'}: $detail (${sw.elapsed.inSeconds}s)');
  return _Step(name, ok, detail, sw.elapsed);
}

/// Runs `flutter test` (JSON reporter) and applies the shared verdict rule.
Future<(bool, String)> _flutterTests(
  String flutter,
  String cwd,
  List<String> files,
  String logBase,
) async {
  Directory(File(logBase).parent.path).createSync(recursive: true);
  final Process p = await Process.start(
    flutter,
    <String>[
      'test',
      '--no-pub',
      '--reporter',
      'json',
      '--exclude-tags',
      'golden',
      ...files
    ],
    workingDirectory: cwd,
    runInShell: Platform.isWindows,
  );
  final List<String> lines = <String>[];
  final IOSink log = File('$logBase.jsonl').openWrite();
  final IOSink err = File('$logBase.stderr.log').openWrite();
  const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
  final Future<void> out = p.stdout
      .transform(decoder)
      .transform(const LineSplitter())
      .forEach((String l) {
    lines.add(l);
    log.writeln(l);
  });
  final Future<void> errDone = p.stderr.transform(decoder).forEach((String c) {
    err.write(c);
    stderr.write(c);
  });
  final int code = await p.exitCode;
  await Future.wait(<Future<void>>[out, errDone]);
  await log.close();
  await err.close();
  final FlutterTestRunSummary summary = parseFlutterTestJsonEvents(lines);
  final String? failure =
      resolveFlutterTestVerdictFailure(flutterExitCode: code, summary: summary);
  if (failure != null) {
    stderr.writeln(renderFlutterTestFailureSummary(
      summary,
      logPath: '$logBase.jsonl',
      stderrLogPath: '$logBase.stderr.log',
    ));
    return (false, failure);
  }
  return (true, '${summary.testsCompleted} tests passed');
}

Future<int> _stream(String exe, List<String> args, String cwd) async {
  final Process p = await Process.start(exe, args,
      workingDirectory: cwd,
      runInShell: Platform.isWindows,
      mode: ProcessStartMode.inheritStdio);
  return p.exitCode;
}

void _report(List<_Step> steps) {
  final bool ok = steps.every((_Step s) => s.ok);
  stdout.writeln('\n==== pre-push summary');
  for (final _Step s in steps) {
    stdout.writeln('  ${s.ok ? 'OK    ' : 'FAILED'}  ${s.name}  '
        '(${s.elapsed.inSeconds}s)  ${s.ok ? '' : s.detail}');
  }
  stdout.writeln(ok
      ? 'PRE-PUSH VERDICT: PASSED'
      : 'PRE-PUSH VERDICT: FAILED - fix the steps above before pushing');
  exitCode = ok ? 0 : 1;
}

Never _fail(String message) {
  stderr.writeln('pre-push: $message');
  exit(2);
}

/// Changed files since the merge base with [base] (default upstream/develop,
/// else origin/develop), plus uncommitted and untracked files. The merge base
/// matters: diffing against a moving develop would count other people's
/// merges as "my changes" (tests_for_changes.dart hit exactly that).
List<String> _changedFromGit(String root, String? base) {
  String? ref = base;
  if (ref == null) {
    for (final String candidate in <String>[
      'upstream/develop',
      'origin/develop'
    ]) {
      final ProcessResult r = Process.runSync(
          'git', <String>['rev-parse', '--verify', '--quiet', candidate],
          workingDirectory: root);
      if (r.exitCode == 0) {
        ref = candidate;
        break;
      }
    }
  }
  if (ref == null) {
    _fail(
        'no --base given and neither upstream/develop nor origin/develop exists');
  }
  final ProcessResult mb = Process.runSync(
      'git', <String>['merge-base', 'HEAD', ref],
      workingDirectory: root);
  if (mb.exitCode != 0) _fail('git merge-base HEAD $ref failed: ${mb.stderr}');
  final String mergeBase = (mb.stdout as String).trim();
  final ProcessResult diff = Process.runSync(
      'git', <String>['diff', '--name-only', mergeBase],
      workingDirectory: root);
  final ProcessResult untracked = Process.runSync(
      'git', <String>['ls-files', '--others', '--exclude-standard'],
      workingDirectory: root);
  return <String>[
    ...(diff.stdout as String).split(RegExp(r'\r?\n')),
    ...(untracked.stdout as String).split(RegExp(r'\r?\n')),
  ].map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
}

Map<String, String> _packageNames(String root) {
  final Map<String, String> out = <String, String>{};
  final Directory dir = Directory('$root/packages');
  if (!dir.existsSync()) return out;
  for (final Directory d in dir.listSync().whereType<Directory>()) {
    final File pubspec = File('${d.path}/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final Match? m = RegExp(r'^name:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec.readAsStringSync());
    if (m != null) {
      out[d.uri.pathSegments.where((String s) => s.isNotEmpty).last] =
          m.group(1)!;
    }
  }
  return out;
}

/// The flutter of the SDK whose dart runs this tool
/// (`<flutter>/bin/cache/dart-sdk/bin/dart`), then FLUTTER_ROOT, then PATH.
String _flutterExecutable() {
  final String name = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final List<String> seg =
      Platform.resolvedExecutable.replaceAll('\\', '/').split('/');
  final int cache = seg.lastIndexOf('cache');
  if (cache >= 2 && seg[cache - 1] == 'bin') {
    final String candidate = '${seg.sublist(0, cache).join('/')}/$name';
    if (File(candidate).existsSync()) return candidate;
  }
  final String? envRoot = Platform.environment['FLUTTER_ROOT'];
  if (envRoot != null && File('$envRoot/bin/$name').existsSync()) {
    return '$envRoot/bin/$name';
  }
  return 'flutter';
}

String? _ciFlutterVersion(String root) {
  final File wf = File('$root/.github/workflows/main.yml');
  if (!wf.existsSync()) return null;
  return RegExp(r'''flutter-version:\s*['"]?(\d+\.\d+\.\d+)''')
      .firstMatch(wf.readAsStringSync())
      ?.group(1);
}

String? _localFlutterVersion(String flutter) {
  final ProcessResult r = Process.runSync(
      flutter, <String>['--version', '--machine'],
      runInShell: Platform.isWindows);
  if (r.exitCode != 0) return null;
  final String out = r.stdout as String;
  final int brace = out.indexOf('{');
  if (brace < 0) return null;
  try {
    final Object? json = jsonDecode(out.substring(brace));
    return json is Map ? json['frameworkVersion'] as String? : null;
  } on FormatException {
    return null;
  }
}
