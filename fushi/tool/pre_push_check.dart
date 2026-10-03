// Pre-push check: the parts of CI a local run can reproduce cheaply, in one
// command, so that "it passed locally" means "CI will not turn red on it".
//
//   dart run tool/pre_push_check.dart [--base=<ref>] [--list] [--quick|--wide]
//                                     [--skip-analyze] [--parallel]
//                                     [--concurrency=4] [--batch-size=20]
//                                     [--gate=1] [--gate-timeout-min=0]
//                                     [--no-lease] [--max-minutes=90]
//                                     [--allow-flutter-mismatch]
//                                     [--files <paths...> | --files-from=<list>]
//
// Resource budget (2026-09-30: three agents running this at once took a 32 GB
// machine down to ~1 GB free; one run was 4-6 GB because `flutter test` ran at
// the default concurrency -- a dozen flutter_testers on 16 cores -- alongside a
// full `flutter analyze`, and load-induced 30 s timeouts then failed the verdict):
//   * tests run with --concurrency=4, in batches of at most --batch-size files;
//   * analyze runs after the tests, not alongside (--parallel restores the old
//     overlap for a machine nobody else is using);
//   * every `flutter test` batch and every analyze holds the machine-wide
//     heavy-run lease (test_flow/heavy_lease.dart, shared with tool/heavy.dart
//     and flutter_test_failures.dart): an OS-locked slot and the worktree's
//     build/ to itself (no memory admission since 2026-10-03). Steps queue
//     first come, first served until admitted; only an explicit
//     --gate-timeout-min=N fails a step not admitted in time. The old
//     process-counting gate ran "anyway" and raced, which is how the machine
//     ran out of memory. --gate=0 turns the lease off;
//   * the tool runs in a Windows Job Object: below-normal priority, a memory
//     ceiling, and its whole process tree dies with it. --gate=0 drops the job
//     too; --no-lease (for a caller that schedules runs itself, such as
//     mac-offload's slots) drops the lease and the memory ceiling but keeps
//     the priority and the kill-on-exit;
//   * --max-minutes (0 disables) caps the time the tool's own subprocesses run
//     (gate waits excluded): past it the running subprocess trees are killed and
//     the verdict is FAILED. A session that dies mid-run leaves this tool behind;
//     without the cap it kept starting new batches for hours.
//
// Why (upstream 2026-09-20..30): agents ran `flutter analyze` + hand-picked tests
// before pushing, yet CI went red. analyze failed once in 10 days; of the 36 PRs
// whose CI caught a regression they introduced, 15 were red only on source-scan
// guards and 3 on guards plus other tests. Those guards name the files they
// scan by path literal (tool/tests_for_changes.dart derives them), or scan whole
// trees (the enumeration batch in docs/agent/fast-workflow.md, which the rules
// only ran AFTER merging). This tool runs, in order:
//   0. toolchain: the local Flutter must be the version CI pins (main.yml);
//   1. app tests: the enumeration guard batch + path-literal-triggered tests
//      (tests_for_changes, Dart trees included) + tests importing a changed
//      library / helper + changed test files -- first, because the guards are
//      where the regressions were caught;
//   2. tests of changed packages (as main.yml's package loop / server-gate);
//   3. the JS suites when JS / assets / the extension changed;
//   4. full `flutter analyze` in fushi/ (analyzing only changed files misses
//      callers broken by an API change), plus `dart analyze` of the pure-Dart
//      packages CI analyzes separately when they changed.
// Every Flutter test batch is judged by exit code AND executed count (BUG-1157).
// The full sharded suite still runs on CI; this is the cheap, high-yield subset.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'test_flow/flutter_test_failure_filter.dart';
import 'test_flow/heavy_budget.dart';
import 'test_flow/heavy_lease.dart';
import 'test_flow/pre_push_selection.dart';
import 'tests_for_changes.dart'
    show
        RepoFs,
        TestTriggerFace,
        buildReferenceIndex,
        changeTriggersReference,
        extractRepoPathReferences,
        globToRegExp,
        listAppTestFiles,
        locateRepoRoot,
        normalizeChangedPath;

class _Step {
  _Step(this.name, this.ok, this.detail, this.elapsed);
  final String name;
  final bool ok;
  final String detail;
  final Duration elapsed;
}

/// The machine-wide heavy-run lease (test_flow/heavy_lease.dart) around every
/// Flutter test batch and analyze: a free slot and, for test batches, this
/// worktree's build/ to itself. Steps queue until admitted; only with an
/// explicit --gate-timeout-min=N does a step that is never admitted fail (it
/// is not run "anyway": that is what took the machine down); --gate=0 and
/// --no-lease turn the lease off.
class _Leases {
  _Leases({required this.enabled, required this.waitMax, required this.root});

  final bool enabled;
  final Duration? waitMax;
  final String root;
  final List<String> notes = <String>[];

  /// The tool's Job Object (null where unsupported), for the cap report.
  HeavyJob? job;

  /// Set when a step was not admitted: the machine is busy, so the remaining
  /// steps are not queued for another --gate-timeout-min each (that is hours).
  bool _refused = false;

  Future<(bool, String)> run(HeavyKind kind, String what,
      Future<(bool, String)> Function() body) async {
    if (!enabled) return body();
    if (_refused) {
      return (false, 'not run: an earlier step was not admitted');
    }
    final HeavyLease lease;
    try {
      lease = await acquireHeavyLease(
        need: heavyNeedFor(kind),
        label: 'pre-push $what',
        worktreeRoot: root,
        waitMax: waitMax,
        log: (String l) => stdout.writeln('   $l'),
      );
    } on HeavyLeaseTimeout catch (e) {
      _refused = true;
      notes.add('$what not admitted: ${e.message}');
      return (
        false,
        'not run: the machine had no room within ${waitMax?.inMinutes} min '
            '(see gate notes)'
      );
    }
    if (lease.skipReason != null && notes.isEmpty) {
      notes.add('no lease taken (${lease.skipReason})');
    }
    if (lease.waited.inSeconds >= 30) {
      notes.add('$what waited ${lease.waited.inMinutes} min for the machine');
    }
    try {
      return await body();
    } finally {
      lease.release();
      final int? peak = job?.peakMb();
      final int? cap = job?.capMb;
      if (peak != null && cap != null && heavyCapHit(peak, cap)) {
        notes.add('MEMORY CAP HIT during $what ($peak of $cap MB): its '
            'failures can come from the ceiling, not from the code');
      }
    }
  }
}

/// `(pid, parent pid)` of every process on this machine; empty when unreadable.
List<(int, int)> _processTable() {
  try {
    final ProcessResult r = Platform.isWindows
        ? Process.runSync('powershell', <String>[
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'''Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId)" }''',
          ])
        : Process.runSync('ps', <String>['-Ao', 'pid=,ppid=']);
    if (r.exitCode != 0) return const <(int, int)>[];
    return <(int, int)>[
      for (final String line
          in const LineSplitter().convert(r.stdout as String))
        if (RegExp(r'^\s*(\d+)\s+(\d+)\s*$').firstMatch(line)
            case final RegExpMatch m)
          (int.parse(m.group(1)!), int.parse(m.group(2)!)),
    ];
  } on ProcessException {
    return const <(int, int)>[];
  }
}

/// Kills [root] and every descendant (flutter_tester, frontend_server, ...);
/// returns how many processes that was.
int _killTree(int root) {
  final List<int> descendants = descendantPids(root, _processTable());
  if (Platform.isWindows) {
    // /T takes the whole tree; the pids above are only counted (taskkill's own
    // output is localized).
    Process.runSync('taskkill', <String>['/PID', '$root', '/T', '/F']);
  } else {
    for (final int pid in <int>[...descendants, root]) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }
  return descendants.length + 1;
}

/// --max-minutes: the time the tool's own subprocesses run, gate waits
/// excluded. Past the limit the running subprocess trees are killed and no
/// further step starts.
class _Budget {
  _Budget(this.limit);

  final Duration limit;
  final Stopwatch _active = Stopwatch();
  final Set<Process> _running = <Process>{};
  Timer? _timer;
  bool exceeded = false;
  int killed = 0;

  /// Registers a started subprocess and waits for its exit code.
  Future<int> run(Process p) async {
    _running.add(p);
    if (_running.length == 1) _active.start();
    if (limit > Duration.zero) {
      _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => _check());
    }
    try {
      return await p.exitCode;
    } finally {
      _running.remove(p);
      if (_running.isEmpty) _active.stop();
    }
  }

  void _check() {
    if (exceeded || _active.elapsed <= limit) return;
    exceeded = true;
    stdout.writeln('   budget: subprocesses have run '
        '${_active.elapsed.inMinutes} min > ${limit.inMinutes}; killing them');
    for (final Process p in _running.toList()) {
      killed += _killTree(p.pid);
    }
  }

  void dispose() => _timer?.cancel();
}

/// The run's budget; main replaces it with the --max-minutes one.
_Budget _budget = _Budget(Duration.zero);

Future<void> main(List<String> args) async {
  final RepoFs fs = RepoFs(locateRepoRoot(Directory.current));
  final String root = fs.root.path;
  final bool listOnly = args.contains('--list');
  final bool skipAnalyze = args.contains('--skip-analyze');
  final bool parallel = args.contains('--parallel');
  final bool allowMismatch = args.contains('--allow-flutter-mismatch');
  final int concurrency = _intArg(args, '--concurrency=', 4);
  final int batchSize = _intArg(args, '--batch-size=', 20);
  final bool noLease = args.contains('--no-lease');
  final _Leases gate = _Leases(
    enabled: !noLease && _intArg(args, '--gate=', 1) > 0,
    waitMax: _intArg(args, '--gate-timeout-min=', 0) > 0
        ? Duration(minutes: _intArg(args, '--gate-timeout-min=', 0))
        : null,
    root: root,
  );
  // A typical run is 3-15 minutes of subprocess time.
  _budget = _Budget(Duration(minutes: _intArg(args, '--max-minutes=', 90)));
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
  // Budget mode (default) keeps the local run to a few minutes; --wide uses
  // tests_for_changes' full rule (siblings + any-size directories, all import
  // hubs), which on real PRs selected 600-1500 test files.
  final bool wide = args.contains('--wide');
  // --quick: guards only (batch + exact path + via-helper + changed tests), no
  // import expansion -- for iterating; run the default mode before pushing.
  final bool quick = args.contains('--quick');
  final int maxDirFiles = _intArg(args, '--max-dir-files=', 60);
  final int hubLimit = _intArg(args, '--hub-limit=', 40);
  final Map<String, int> dirFiles = <String, int>{};
  int dirFileCount(String rel) => dirFiles.putIfAbsent(
      rel,
      () => Directory('$root/$rel')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .length);
  bool triggers(String c, String ref) => wide
      ? changeTriggersReference(c, ref, fs)
      : budgetTrigger(c, ref,
          isDirectory: fs.isDirectory,
          dirFileCount: dirFileCount,
          maxDirFiles: maxDirFiles);
  final Map<String, Set<String>> byPath = <String, Set<String>>{};
  for (final MapEntry<String, TestTriggerFace> e
      in buildReferenceIndex(fs).entries) {
    for (final String c in changed) {
      for (final String ref in e.value.triggeringPaths) {
        if (triggers(c, ref)) {
          byPath.putIfAbsent(e.key, () => <String>{}).add(ref);
        }
      }
      for (final String g in e.value.declaredGlobs) {
        if (globToRegExp(g).hasMatch(c)) {
          byPath.putIfAbsent(e.key, () => <String>{}).add('glob:$g');
        }
      }
    }
  }
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
  final ({Set<String> kept, Set<String> hubs}) keys = quick
      ? (kept: <String>{}, hubs: <String>{})
      : wide
          ? (kept: importKeys, hubs: <String>{})
          : splitHubImportKeys(importKeys, testSources, hubLimit: hubLimit);
  final Set<String> byImport = directImpactTests(
    changed: changed,
    testSources: testSources,
    importKeys: keys.kept,
  );
  // One hop through shared test helpers: many guards read their target via a
  // corpus helper (e.g. test/pages/video_fushi_page_source_corpus.dart), so the
  // path literal lives in the helper, not the test, and tests_for_changes'
  // per-test index cannot see it (replay of 36 regression PRs missed
  // video_orientation_fullscreen_guard_test this way).
  final Set<String> triggeredHelpers = <String>{};
  for (final FileSystemEntity e in Directory('$root/fushi/test')
      .listSync(recursive: true, followLinks: false)) {
    final String path = e.path.replaceAll('\\', '/');
    if (e is! File || !path.endsWith('.dart') || path.endsWith('_test.dart')) {
      continue;
    }
    final Set<String> refs =
        extractRepoPathReferences(e.readAsStringSync(), fs);
    if (changed.any((String c) => refs.any((String r) => triggers(c, r)))) {
      triggeredHelpers.add(path.split('/').last);
    }
  }
  final Set<String> byHelper = <String>{
    for (final MapEntry<String, String> t in testSources.entries)
      if (triggeredHelpers.any(
          (String h) => t.value.contains("/$h'") || t.value.contains("'$h'")))
        t.key,
  };

  final bool runBatch = touchesDartTrees(changed);
  final List<String> appTests = <String>{
    if (runBatch) ...guards,
    ...byPath.keys.where(testSources.containsKey),
    ...byHelper,
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
    ..writeln('pre-push: ${changed.length} changed file(s), '
        '${quick ? 'QUICK (guards only; run without --quick before pushing)' : wide ? 'wide selection' : 'budget selection (--wide for everything)'}')
    ..writeln('  app tests: ${appTests.length} = '
        '${runBatch ? '${guards.length} enumeration guards' : 'no enumeration batch (no Dart tree changed)'}'
        ' + ${byPath.length} path-literal + ${byHelper.length} via-helper'
        ' + ${byImport.length} import-impact '
        '(deduplicated)')
    ..writeln(keys.hubs.isEmpty
        ? '  import hubs skipped: -'
        : '  import hubs skipped (imported by >$hubLimit tests; the sharded CI '
            'suite covers their importers): ${keys.hubs.join(', ')}')
    ..writeln(
        '  package tests: ${packages.isEmpty ? '-' : packages.join(', ')}')
    ..writeln('  separate dart analyze: '
        '${analyzePackages.isEmpty ? '-' : analyzePackages.join(', ')}')
    ..writeln('  JS suites: ${js ? 'yes' : 'no'}')
    // ~3 s per test file measured on a machine shared by several agents
    // (69 files 218 s, 110 files 334 s); analyze ~2-3 min on an idle machine.
    ..writeln(
        '  estimated: ~${(appTests.length * 3 / 60).ceil()} min app tests '
        '(--concurrency=$concurrency, batches of <=$batchSize)'
        '${skipAnalyze ? '' : parallel ? ', analyze alongside' : ' + ~3 min analyze after them'}'
        '${gate.enabled ? '; each step waits for a machine-wide heavy-run slot (dart tool/heavy.dart --status)' : ''}');
  if (listOnly) {
    for (final String t in appTests) {
      final List<String> why = <String>[
        if (runBatch && guards.contains(t)) 'batch',
        if (byPath.containsKey(t)) 'path',
        if (byHelper.contains(t)) 'helper',
        if (byImport.contains(t)) 'import',
      ];
      stdout.writeln('  $t  [${why.join(',')}]');
    }
    return;
  }

  // ---- run ----------------------------------------------------------------
  // Below-normal priority, a memory ceiling (not with --no-lease), and no
  // flutter_tester outliving this tool (one held
  // build/native_assets/windows/sqlite3.dll for the next run).
  if (gate.enabled || noLease) {
    gate.job = joinHeavyJob(
        noLease
            ? null
            : heavyNeedFor(HeavyKind.test).capMb +
                (parallel ? heavyNeedFor(HeavyKind.analyze).capMb : 0),
        log: stdout.writeln);
  }
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

  // Analyze and tests are independent, but each costs 1.5-4 GB: by default the
  // analyze lane starts only after the test lane (measured sequentially: analyze
  // 135 s + 69 test files 218 s). --parallel overlaps them on an idle machine.
  Future<List<_Step>> analyzeLane() async {
    final List<_Step> out = <_Step>[];
    if (skipAnalyze) return out;
    out.add(await _timed(
        'flutter analyze (fushi/)',
        () => gate.run(HeavyKind.analyze, 'flutter analyze', () async {
              // --no-pub: the worktree is bootstrapped; resolving the whole
              // workspace again on every run only costs time.
              final int code = await _stream(
                  flutter, <String>['analyze', '--no-pub'], '$root/fushi');
              return (code == 0, 'exit $code');
            })));
    for (final String p in analyzePackages) {
      out.add(await _timed(
          'dart analyze (packages/$p)',
          () => gate.run(HeavyKind.analyze, 'packages/$p analyze', () async {
                final int code = await _stream(
                    dart, <String>['analyze'], '$root/packages/$p');
                return (code == 0, 'exit $code');
              })));
    }
    return out;
  }

  Future<List<_Step>> testLane() async {
    final List<_Step> out = <_Step>[];
    final List<List<String>> batches = chunkByCommandLength(
      appTests.map((String t) => t.substring('fushi/'.length)).toList(),
      maxFiles: batchSize,
    );
    for (int i = 0; i < batches.length; i++) {
      out.add(await _timed(
        'app tests ${i + 1}/${batches.length} (${batches[i].length} files)',
        () => gate.run(
            HeavyKind.test,
            'app test batch ${i + 1}/${batches.length}',
            () => _flutterTests(flutter, '$root/fushi', batches[i],
                '$root/.codex-test/pre-push/app-$i', concurrency)),
      ));
    }
    for (final String p in packages) {
      out.add(await _timed(
          'package tests (packages/$p)',
          () => gate.run(
              HeavyKind.test,
              'packages/$p tests',
              () => _flutterTests(
                  flutter,
                  '$root/packages/$p',
                  const <String>[],
                  '$root/.codex-test/pre-push/pkg-$p',
                  concurrency))));
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
  }

  if (parallel) {
    final List<List<_Step>> lanes =
        await Future.wait(<Future<List<_Step>>>[testLane(), analyzeLane()]);
    steps
      ..addAll(lanes[0])
      ..addAll(lanes[1]);
  } else {
    steps
      ..addAll(await testLane())
      ..addAll(await analyzeLane());
  }
  _report(steps, gateNotes: gate.notes);
}

int _intArg(List<String> args, String prefix, int fallback) {
  for (final String a in args) {
    if (a.startsWith(prefix)) {
      return int.tryParse(a.substring(prefix.length)) ?? fallback;
    }
  }
  return fallback;
}

Future<_Step> _timed(
    String name, Future<(bool, String)> Function() body) async {
  stdout.writeln('\n== $name');
  if (_budget.exceeded) {
    stdout.writeln('   -> FAILED: not run (--max-minutes budget exceeded)');
    return _Step(name, false, 'not run: budget exceeded', Duration.zero);
  }
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
  int concurrency,
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
      // The default is one flutter_tester per core (a dozen+ on the agents'
      // 16-core machine, 150-450 MB each); 4 keeps a run near 2 GB.
      '--concurrency=$concurrency',
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
  final int code = await _budget.run(p);
  await Future.wait(<Future<void>>[out, errDone]);
  await log.close();
  await err.close();
  final FlutterTestRunSummary summary = parseFlutterTestJsonEvents(lines);
  if (_budget.exceeded) {
    // Not a compile failure or a red test: this batch was cut off.
    return (
      false,
      'killed by the --max-minutes budget after '
          '${summary.testsCompleted} test(s)',
    );
  }
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
  return _budget.run(p);
}

void _report(List<_Step> steps, {List<String> gateNotes = const <String>[]}) {
  _budget.dispose();
  final bool ok = !_budget.exceeded && steps.every((_Step s) => s.ok);
  stdout.writeln('\n==== pre-push summary');
  for (final _Step s in steps) {
    stdout.writeln('  ${s.ok ? 'OK    ' : 'FAILED'}  ${s.name}  '
        '(${s.elapsed.inSeconds}s)  ${s.ok ? '' : s.detail}');
  }
  for (final String n in gateNotes) {
    stdout.writeln('  gate: $n');
  }
  if (_budget.exceeded) {
    stdout.writeln('  budget: subprocess time exceeded '
        '${_budget.limit.inMinutes} min (--max-minutes); killed '
        '${_budget.killed} process(es)');
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
