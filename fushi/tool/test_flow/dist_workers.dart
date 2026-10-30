/// Workers of `tool/dist_test.dart`: the local checkout, and machines reached
/// over ssh. Config: `tool/dist_test/workers.local.json` (git-ignored; see
/// `workers.example.json` next to it).
///
/// Connections only ever go from this machine to a worker. Every ssh / git
/// call carries [kDistSshOptions], which turn off agent, X11 and port
/// forwarding: with agent forwarding on, an admin of the worker could use this
/// machine's agent to log in elsewhere as you.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dist_coverage.dart';
import 'dist_plan.dart';
import 'dist_results.dart';
import 'dist_snapshot.dart';
import 'flutter_sdk_executables.dart';
import 'heavy_budget.dart';
import 'heavy_lease.dart';

/// Options on every ssh connection (also used as `GIT_SSH_COMMAND` for the
/// snapshot push).
const List<String> kDistSshOptions = <String>[
  '-o', 'BatchMode=yes', //
  '-o', 'ForwardAgent=no',
  '-o', 'ForwardX11=no',
  '-o', 'ClearAllForwardings=yes',
  '-o', 'PermitLocalCommand=no',
  '-o', 'ConnectTimeout=15',
  '-o', 'ServerAliveInterval=15',
  '-o', 'ServerAliveCountMax=4',
];

/// Path characters per local `flutter test` process (cmd.exe stops at 8191).
const int kLocalMaxCommandChars = 6000;

/// The ssh client for remote commands. On Windows the system OpenSSH
/// (native Win32 pipes): Git for Windows' msys `ssh.exe`, which PATH often
/// finds first, emulates select() over the pipes Dart hands it and stalled a
/// batch mid-line (the remote run had finished; the stream never arrived).
/// `FUSHI_DIST_SSH` overrides. The snapshot push keeps git's own ssh.
/// bash for the worker-side scripts run on this machine: Git for Windows' own
/// on Windows (never the WSL `bash.exe` System32 may put first on PATH).
String distBashExecutable() {
  if (!Platform.isWindows) return 'bash';
  final String exec =
      '${Process.runSync('git', <String>['--exec-path']).stdout}'.trim();
  // <Git>/mingw64/libexec/git-core -> <Git>/bin/bash.exe
  return '${File(exec).parent.parent.parent.path}/bin/bash.exe';
}

String distSshExecutable([Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String? override = env['FUSHI_DIST_SSH'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) {
    final String system =
        '${env['SystemRoot'] ?? r'C:\Windows'}'
        r'\System32\OpenSSH\ssh.exe';
    if (File(system).existsSync()) return system;
  }
  return 'ssh';
}

/// The ssh program git uses for the snapshot push: `FUSHI_DIST_SSH` when set
/// (so a test transport carries both), otherwise git's own `ssh`.
String distGitSshProgram([Map<String, String>? environment]) {
  final String? override =
      (environment ?? Platform.environment)['FUSHI_DIST_SSH'];
  if (override != null && override.isNotEmpty) {
    // GIT_SSH_COMMAND goes through git's sh: forward slashes, quoted.
    return shellQuote(override.replaceAll('\\', '/'));
  }
  return 'ssh';
}

/// Proxy variables never reach a test process: CI has none, and a
/// `NO_PROXY=127.0.0.1` makes ffmpeg drop an explicit `-http_proxy`, which
/// turns the media relay tests red on a machine that only set a proxy for
/// GitHub. ssh workers get them only in the prepare step (prepareEnv).
const Set<String> kDistStrippedTestEnv = <String>{
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'ALL_PROXY',
  'NO_PROXY',
};

/// [parent] without [kDistStrippedTestEnv] (case-insensitively).
Map<String, String> distTestEnvironment(Map<String, String> parent) =>
    <String, String>{
      for (final MapEntry<String, String> e in parent.entries)
        if (!kDistStrippedTestEnv.contains(e.key.toUpperCase())) e.key: e.value,
    };

/// A remote checkout lock without a heartbeat for this long is taken over:
/// its coordinator died (worker_run.sh touches it every minute while a batch
/// runs, and no other step takes that long).
const int kDistLockStaleMinutes = 15;

/// ssh's own exit code for connection-level failures.
const int kSshConnectionFailure = 255;

/// `worker_shim.sh`: the worker refuses work for now (paused by its owner,
/// low memory / disk). Not a failure of the batch.
const int kDistShimBusy = 75;

/// `worker_shim.sh`: the request itself is refused (unknown verb, bad
/// argument).
const int kDistShimRefused = 2;

enum DistWorkerKind {
  /// This checkout, through the machine-wide heavy lease.
  local,

  /// A machine of your own reached by ssh with a normal shell.
  sshTrusted,

  /// Someone else's machine: the key is pinned to `worker_shim.sh` there
  /// (`restrict,command=`), so every request is one of the shim's verbs and
  /// the coordinator never gets a shell. Paths, PATH, proxy and limits are
  /// the owner's settings on that machine, not part of this config.
  sshShim,
}

class DistConfigError implements Exception {
  DistConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

class DistWorkerConfig {
  const DistWorkerConfig({
    required this.name,
    required this.kind,
    required this.platform,
    this.host,
    this.identity,
    this.workdir = 'fushi-dist/work',
    this.seedRepo,
    this.path = const <String>[],
    this.prepareEnv = const <String, String>{},
    this.concurrency,
    this.capabilities = const <String>{},
    this.slots = 1,
    this.nativePeer,
    this.slotIndex = 1,
  });

  final String name;
  final DistWorkerKind kind;
  final DistPlatform platform;

  /// `user@host` for ssh workers.
  final String? host;

  /// Private key for this worker only (`-i`, with `IdentitiesOnly=yes`).
  final String? identity;

  /// Checkout directory on the worker, relative to the remote home.
  final String workdir;

  /// Existing clone on the worker (relative to its home) whose objects seed a
  /// fresh [workdir] through `objects/info/alternates`, so the first push only
  /// sends what that clone lacks.
  final String? seedRepo;

  /// Entries prepended to the remote PATH (a non-interactive ssh shell does
  /// not read the login profile). `$HOME` is expanded remotely.
  final List<String> path;

  /// Extra environment for the prepare step only (pub get / native builds /
  /// hook downloads), e.g. a proxy. Tests run without it, as on CI.
  final Map<String, String> prepareEnv;

  /// `flutter test --concurrency`; null = flutter's default.
  final int? concurrency;
  final Set<String> capabilities;

  /// Independent checkouts on this machine, each running its own
  /// `flutter test`. One process compiles its suites one at a time (measured
  /// on the M4 Mac: ~1.4 s per suite whatever `--concurrency` is), so more
  /// processes is what uses more cores; they cannot share a checkout (they
  /// fight over build/native_assets). ssh workers only.
  final int slots;

  /// Primary slot's checkout (relative to the remote home) a secondary slot
  /// copies matching native libraries from instead of building them again.
  final String? nativePeer;

  /// Which of the machine's [slots] this is (1-based); the shim addresses its
  /// checkouts by it.
  final int slotIndex;

  /// Slot [index] (2..[slots]) of this machine: its own checkout next to the
  /// primary one, seeded from the primary's objects.
  DistWorkerConfig slot(int index) => DistWorkerConfig(
    name: '$name.$index',
    kind: kind,
    platform: platform,
    host: host,
    identity: identity,
    workdir: '$workdir-$index',
    seedRepo: workdir,
    path: path,
    prepareEnv: prepareEnv,
    concurrency: concurrency,
    capabilities: capabilities,
    nativePeer: workdir,
    slotIndex: index,
  );

  static final RegExp _name = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _host = RegExp(r'^[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+$');
  static final RegExp _relPath = RegExp(r'^[A-Za-z0-9_./-]+$');
  static final RegExp _pathEntry = RegExp(r'^[A-Za-z0-9_./$~-]+$');
  static final RegExp _envKey = RegExp(r'^[A-Z_][A-Z0-9_]*$');

  static DistWorkerConfig fromJson(Map<String, Object?> json) {
    String str(String key, {bool required = false}) {
      final Object? v = json[key];
      if (v is String) return v;
      if (required || v != null) {
        throw DistConfigError(
          'worker ${json['name']}: "$key" must be a '
          'string',
        );
      }
      return '';
    }

    final String name = str('name', required: true);
    if (!_name.hasMatch(name)) {
      throw DistConfigError('worker name "$name": use [A-Za-z0-9_-]');
    }
    final DistWorkerKind kind = switch (str('kind', required: true)) {
      'local' => DistWorkerKind.local,
      'ssh-trusted' => DistWorkerKind.sshTrusted,
      'ssh-shim' => DistWorkerKind.sshShim,
      final String other => throw DistConfigError(
        'worker $name: unknown kind "$other" (local / ssh-trusted / ssh-shim)',
      ),
    };
    final DistPlatform platform = switch (str('os', required: true)) {
      'windows' => DistPlatform.windows,
      'macos' => DistPlatform.macos,
      final String other => throw DistConfigError(
        'worker $name: unknown os "$other"',
      ),
    };
    if (kind == DistWorkerKind.sshShim) {
      for (final String key in <String>[
        'workdir',
        'seedRepo',
        'path',
        'prepareEnv',
      ]) {
        if (json.containsKey(key)) {
          throw DistConfigError(
            'worker $name: "$key" is the machine owner\'s setting on an '
            'ssh-shim worker (~/.fushi-worker), not part of this config',
          );
        }
      }
    }
    if (kind == DistWorkerKind.sshShim &&
        ((json['capabilities'] as List<Object?>?) ?? const <Object?>[])
            .contains(kDistItestCapability)) {
      // The shim runs unit tests only (worker_run.sh is reached with a
      // numeric concurrency); integration tests build and launch the app on
      // the machine's desktop, which is not what its owner signed up for.
      throw DistConfigError(
        'worker $name: "$kDistItestCapability" is for your own machines '
        '(kind "local" or "ssh-trusted"), not an ssh-shim worker',
      );
    }
    if (kind == DistWorkerKind.sshTrusted && platform == DistPlatform.windows) {
      throw DistConfigError(
        'worker $name: a Windows worker is reached through the shim '
        '(kind "ssh-shim"; Windows sshd does not give a POSIX shell)',
      );
    }
    String? host;
    if (kind != DistWorkerKind.local) {
      host = str('host', required: true);
      if (!_host.hasMatch(host)) {
        throw DistConfigError('worker $name: host must be user@host');
      }
    }
    final String workdir = json['workdir'] == null
        ? 'fushi-dist/work'
        : str('workdir');
    final String seed = str('seedRepo');
    for (final String p in <String>[workdir, if (seed.isNotEmpty) seed]) {
      if (!_relPath.hasMatch(p) || p.split('/').contains('..')) {
        throw DistConfigError(
          'worker $name: "$p" must be a plain path '
          'relative to the remote home',
        );
      }
    }
    final List<String> path = <String>[
      for (final Object? e in (json['path'] as List<Object?>?) ?? <Object?>[])
        e is String && _pathEntry.hasMatch(e)
            ? e
            : throw DistConfigError('worker $name: bad path entry "$e"'),
    ];
    final Map<String, String> prepareEnv = <String, String>{};
    final Object? env = json['prepareEnv'];
    if (env is Map<String, Object?>) {
      for (final MapEntry<String, Object?> e in env.entries) {
        if (!_envKey.hasMatch(e.key) || e.value is! String) {
          throw DistConfigError('worker $name: bad prepareEnv "${e.key}"');
        }
        prepareEnv[e.key] = e.value! as String;
      }
    }
    final Object? concurrency = json['concurrency'];
    if (concurrency != null && (concurrency is! int || concurrency < 1)) {
      throw DistConfigError('worker $name: concurrency must be >= 1');
    }
    final Object? slots = json['slots'];
    if (slots != null && (slots is! int || slots < 1 || slots > 8)) {
      throw DistConfigError('worker $name: slots must be 1..8');
    }
    if (kind == DistWorkerKind.local && slots != null && slots != 1) {
      throw DistConfigError('worker $name: a local worker has one slot');
    }
    final String identity = str('identity');
    return DistWorkerConfig(
      name: name,
      kind: kind,
      platform: platform,
      host: host,
      identity: identity.isEmpty ? null : identity,
      workdir: workdir,
      seedRepo: seed.isEmpty ? null : seed,
      path: path,
      prepareEnv: prepareEnv,
      concurrency: concurrency as int?,
      capabilities: <String>{
        for (final Object? c
            in (json['capabilities'] as List<Object?>?) ?? <Object?>[])
          if (c is String) c,
      },
      slots: (slots as int?) ?? 1,
    );
  }
}

/// Reads `{"workers": [...]}`.
List<DistWorkerConfig> readDistWorkers(String text) {
  final Object? decoded = jsonDecode(text);
  final Object? workers = decoded is Map<String, Object?>
      ? decoded['workers']
      : null;
  if (workers is! List<Object?>) {
    throw DistConfigError('expected {"workers": [...]}');
  }
  final List<DistWorkerConfig> configs = <DistWorkerConfig>[
    for (final Object? w in workers)
      w is Map<String, Object?>
          ? DistWorkerConfig.fromJson(w)
          : throw DistConfigError('worker entries must be objects'),
  ];
  final Set<String> names = <String>{};
  for (final DistWorkerConfig c in configs) {
    if (!names.add(c.name)) throw DistConfigError('duplicate worker ${c.name}');
  }
  if (configs
          .where((DistWorkerConfig c) => c.kind == DistWorkerKind.local)
          .length >
      1) {
    throw DistConfigError('at most one local worker');
  }
  return configs;
}

/// POSIX single-quote.
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// The raw result of one batch process.
class DistBatchRun {
  const DistBatchRun({
    required this.exitCode,
    required this.lines,
    this.infraError,
    this.busy,
    this.coverage = const <String>[],
  });

  final int exitCode;
  final List<String> lines;

  /// lcov texts of a `--coverage` batch (taken out of [lines]), one per
  /// `flutter test` process; unchecked worker data (dist_coverage.dart).
  final List<String> coverage;

  /// The run did not get a fair chance (connection lost, timed out, killed);
  /// the scheduler may hand the batch to another worker.
  final String? infraError;

  /// The worker turned the batch down before running it ([kDistShimBusy]):
  /// its owner paused it, or memory is short. Nothing ran.
  final String? busy;

  /// Paused by the owner: no point asking again during this run.
  bool get paused => busy != null && busy!.contains('paused');
}

/// Work `dist_test.dart` hands whole to one other machine, instead of test
/// batches: `flutter analyze`, or a compile check.
class DistJob {
  const DistJob.analyze() : build = null;
  const DistJob.build(DistBuild this.build);

  final DistBuild? build;

  String get label => build == null ? 'analyze' : 'build ${build!.label}';
}

/// worker_shim.sh's `hello` (`key=value` lines).
Map<String, String> parseDistHello(String text) => <String, String>{
  for (final String line in const LineSplitter().convert(text))
    if (line.contains('='))
      line.substring(0, line.indexOf('=')).trim(): line
          .substring(line.indexOf('=') + 1)
          .trim(),
};

/// Why a worker whose `hello` said [hello] cannot take [job]; null when it
/// can. [shim]: an ssh-shim worker (a trusted one runs whatever script its
/// checkout has, so only its toolchains matter).
String? distJobBlocker(
  Map<String, String> hello,
  DistJob job, {
  required bool shim,
}) {
  final DistBuild? build = job.build;
  if (build == null) {
    if (shim && hello['analyze'] != 'yes') {
      return 'its shim predates analyze (the owner re-runs worker_setup)';
    }
  } else {
    final String? have = hello['build'];
    if (have == null) {
      return 'its shim predates builds (the owner re-runs worker_setup)';
    }
    if (have == 'off') return 'builds turned off by the owner (ALLOW_BUILD=0)';
    if (!have.split(',').contains(build.toolchain.name)) {
      return 'no ${build.toolchain.name} toolchain there'
          '${have.isEmpty ? '' : ' (has: $have)'}';
    }
  }
  if (hello['paused'] == 'yes') return 'paused by the owner';
  return null;
}

class DistWorkerError implements Exception {
  DistWorkerError(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class DistWorker {
  DistWorker(this.config);

  final DistWorkerConfig config;

  String get name => config.name;

  /// The physical machine (slots of one machine share it).
  String get machine => config.host ?? 'local';

  /// Integration tests only on a machine's first slot: one desktop app under
  /// test per machine (they share its screen, GPU and app-level services).
  bool eligible(DistUnit unit) =>
      unit.eligibleFor(config.platform, config.capabilities) &&
      (!isDistItestPath(unit.path) || config.slotIndex == 1);

  /// Gets the worker onto [snapshot] with dependencies and native libraries
  /// ready. Throws [DistWorkerError]; [log] receives the step output.
  Future<void> prepare(DistSnapshot snapshot, String runId, IOSink log);

  /// One batch of [package]'s suites ([kDistAppPackage] or `packages/<name>`;
  /// a pure Dart package runs under `dart test`). With `--coverage` among
  /// [flutterArgs] the batch's lcov comes back in [DistBatchRun.coverage].
  Future<DistBatchRun> run(
    DistBatch batch, {
    required String package,
    required List<String> flutterArgs,
    required IOSink stderrLog,
    required Duration timeout,
  });

  /// `flutter analyze --no-pub [options] [paths]` of the prepared checkout
  /// (tool/dist_test/worker_analyze.sh); [DistBatchRun.lines] is its stdout.
  /// Only other machines analyze: the point is to take the work off this one.
  Future<DistBatchRun> analyze(
    List<String> paths, {
    required List<String> options,
    required IOSink stderrLog,
    required Duration timeout,
  });

  /// The compile check [build] of the prepared checkout
  /// (tool/dist_test/worker_build.sh); [DistBatchRun.lines] is its log.
  /// Nothing it builds comes back. Other machines only, like [analyze].
  Future<DistBatchRun> build(
    DistBuild build, {
    required IOSink stderrLog,
    required Duration timeout,
  });

  /// Why this worker cannot take [job] right now, asked before anything is
  /// pushed or prepared there; null when it can.
  Future<String?> jobBlocker(DistJob job);

  /// Stops waiting on a [prepare] still under way (the run needs this worker
  /// no more): it fails soon after, and [finish] then releases the worker.
  Future<void> abandon() async {}

  /// Kills whatever batch is in flight (Ctrl-C).
  Future<void> cancel();

  /// Drops run-scoped state (snapshot ref, lease).
  Future<void> finish(String runId);

  /// One line for `--status`.
  Future<String> status();
}

/// The workers of one config entry: one per slot.
List<DistWorker> createDistWorkers(
  DistWorkerConfig config, {
  required String repoRoot,
}) {
  switch (config.kind) {
    case DistWorkerKind.local:
      return <DistWorker>[LocalDistWorker(config, repoRoot: repoRoot)];
    case DistWorkerKind.sshTrusted:
    case DistWorkerKind.sshShim:
      final SshDistWorker primary = SshDistWorker(config, repoRoot: repoRoot);
      return <DistWorker>[
        primary,
        for (int i = 2; i <= config.slots; i++)
          SshDistWorker(config.slot(i), repoRoot: repoRoot, primary: primary),
      ];
  }
}

/// Collects a child's stdout lines, mirrors its stderr into [stderrLog], and
/// enforces [timeout] by calling [kill].
Future<DistBatchRun> _drive(
  Process process, {
  required IOSink stderrLog,
  required Duration timeout,
  required Future<void> Function() kill,
  required int Function(int exitCode)? connectionFailure,
  StringBuffer? stderrCopy,
}) async {
  const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
  final List<String> lines = <String>[];
  final Future<void> out = process.stdout
      .transform(decoder)
      .transform(const LineSplitter())
      .forEach(lines.add);
  final Future<void> err = process.stderr.transform(decoder).forEach((
    String chunk,
  ) {
    stderrLog.write(chunk);
    stderrCopy?.write(chunk);
  });
  bool timedOut = false;
  final Timer timer = Timer(timeout, () {
    timedOut = true;
    unawaited(kill());
  });
  final int exitCode = await process.exitCode;
  timer.cancel();
  await Future.wait(<Future<void>>[out, err]);
  String? infra;
  if (timedOut) {
    infra = 'timed out after ${timeout.inMinutes} min and was killed';
  } else if (connectionFailure != null &&
      connectionFailure(exitCode) == kSshConnectionFailure) {
    infra = 'ssh connection failed (exit $exitCode)';
  }
  return DistBatchRun(exitCode: exitCode, lines: lines, infraError: infra);
}

class LocalDistWorker extends DistWorker {
  LocalDistWorker(super.config, {required this.repoRoot});

  final String repoRoot;
  HeavyLease? _lease;
  Process? _process;

  /// The integration test app is built (once per run, [_runItests]).
  bool _itestBuilt = false;

  String get _fushiDir => '$repoRoot/fushi';

  @override
  Future<void> prepare(DistSnapshot snapshot, String runId, IOSink log) async {
    // pub workspace: the resolution lands in the workspace root's .dart_tool.
    if (!File('$repoRoot/.dart_tool/package_config.json').existsSync() &&
        !File('$_fushiDir/.dart_tool/package_config.json').existsSync()) {
      throw DistWorkerError(
        'local checkout has no pub get yet; run '
        'tool/setup_worktree.ps1 first',
      );
    }
    if (Platform.isWindows) {
      final ProcessResult r = await Process.run('powershell', <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        '$repoRoot/tool/native_libs.ps1',
      ], workingDirectory: repoRoot);
      log
        ..write(r.stdout)
        ..write(r.stderr);
      if (r.exitCode != 0) {
        throw DistWorkerError('tool/native_libs.ps1 failed (${r.exitCode})');
      }
    }
    // One flutter test at a time in this checkout, like every other heavy
    // run on this machine; held for the whole dist run.
    _lease = await acquireHeavyLease(
      need: heavyNeedFor(HeavyKind.test),
      label: 'dist_test local worker $runId',
      worktreeRoot: repoRoot,
    );
  }

  @override
  Future<DistBatchRun> run(
    DistBatch batch, {
    required String package,
    required List<String> flutterArgs,
    required IOSink stderrLog,
    required Duration timeout,
  }) async {
    if (batch.files.any(isDistItestPath)) {
      return _runItests(batch, stderrLog: stderrLog, timeout: timeout);
    }
    final String dir = '$repoRoot/$package';
    final bool dart =
        distTestRunnerOf(File('$dir/pubspec.yaml').readAsStringSync()) ==
        'dart';
    final bool coverage = flutterArgs.contains('--coverage');
    final List<String> args = <String>[
      for (final String a in flutterArgs)
        if (a != '--coverage') a,
    ];
    // cmd.exe (flutter.bat) caps a command line at 8191 characters, so a big
    // batch runs as several back-to-back processes; their event streams are
    // concatenated (each starts with its own `start` event).
    final List<String> lines = <String>[];
    final List<String> lcov = <String>[];
    final Stopwatch elapsed = Stopwatch()..start();
    int exitCode = 0;
    int part = 0;
    for (final List<String> chunk in splitByPathChars(
      batch.files,
      kLocalMaxCommandChars,
    )) {
      final File? covFile = coverage
          ? File(
              '${Directory.systemTemp.path}/dist_cov_${pid}_${batch.id}_${part++}.info',
            )
          : null;
      final Process process = await Process.start(
        dart
            ? FlutterSdkExecutables.current().dart()
            : FlutterSdkExecutables.current().flutter(),
        <String>[
          'test',
          if (!dart) '--no-pub',
          '--reporter',
          'json',
          // The heavy lease books memory for heavy.dart's default.
          '--concurrency=${config.concurrency ?? kDefaultTestConcurrency}',
          if (covFile != null) ...<String>[
            '--coverage',
            '--coverage-path=${covFile.path}',
          ],
          ...args,
          ...chunk,
        ],
        workingDirectory: dir,
        environment: distTestEnvironment(Platform.environment),
        includeParentEnvironment: false,
        runInShell: Platform.isWindows,
      );
      _process = process;
      await process.stdin.close();
      final DistBatchRun run;
      try {
        final Duration left = timeout - elapsed.elapsed;
        run = await _drive(
          process,
          stderrLog: stderrLog,
          timeout: left.isNegative ? Duration.zero : left,
          kill: () async => _killTree(process),
          connectionFailure: null,
        );
      } finally {
        _process = null;
      }
      if (covFile != null && covFile.existsSync()) {
        lcov.add(covFile.readAsStringSync());
        covFile.deleteSync();
      }
      lines.addAll(run.lines);
      if (exitCode == 0) exitCode = run.exitCode;
      if (run.infraError != null) {
        return DistBatchRun(
          exitCode: run.exitCode,
          lines: lines,
          infraError: run.infraError,
          coverage: lcov,
        );
      }
    }
    return DistBatchRun(exitCode: exitCode, lines: lines, coverage: lcov);
  }

  /// Integration tests: the app is built once per run from the generated
  /// entry (tool/dist_test/itest_entry.sh), then each file is one
  /// `flutter drive` launch of that binary under a fresh data root (they
  /// assume a fresh install), off-screen and never taking the focus. Windows
  /// launches go through tool/run_windows_itest.ps1, the one place that
  /// isolates the app's data, WebView2 profile and user directories there;
  /// on macOS the FUSHI_TEST_* switches are set here.
  Future<DistBatchRun> _runItests(
    DistBatch batch, {
    required IOSink stderrLog,
    required Duration timeout,
  }) async {
    if (!batch.files.every(isDistItestPath)) {
      throw DistWorkerError('integration tests run in batches of their own');
    }
    final Stopwatch elapsed = Stopwatch()..start();
    Duration left() {
      final Duration d = timeout - elapsed.elapsed;
      return d.isNegative ? Duration.zero : d;
    }

    final List<String> reports = <String>[];
    int exitCode = 0;
    String? buildFailure;
    if (!_itestBuilt) {
      final DistBatchRun build = await _runLogged(
        await Process.start(
          FlutterSdkExecutables.current().flutter(),
          <String>[
            'build',
            Platform.isWindows ? 'windows' : 'macos',
            '--debug',
            '--no-pub',
            '-t',
            await _writeItestEntry(),
          ],
          workingDirectory: _fushiDir,
          runInShell: Platform.isWindows,
        ),
        stderrLog: stderrLog,
        timeout: left(),
        header: '== building the integration test app',
      );
      if (build.infraError != null) {
        return DistBatchRun(
          exitCode: build.exitCode,
          lines: const <String>[],
          infraError: build.infraError,
        );
      }
      if (build.exitCode == 0) {
        _itestBuilt = true;
      } else {
        buildFailure = build.lines.skip(build.lines.length - 40).join('\n');
      }
    }
    for (final String file in batch.files) {
      final Stopwatch sw = Stopwatch()..start();
      int status;
      String tail;
      if (buildFailure != null) {
        status = 1;
        tail = 'the app did not build:\n$buildFailure';
      } else {
        final DistBatchRun run = await _runLogged(
          await _startItest(file),
          stderrLog: stderrLog,
          timeout: left(),
          header: '== $file',
        );
        if (run.infraError != null) {
          return DistBatchRun(
            exitCode: run.exitCode,
            lines: expandDistItestReports(reports),
            infraError: run.infraError,
          );
        }
        status = run.exitCode;
        final Directory? evidence = _itestEvidence(run.lines);
        tail = _itestTail(run.lines, evidence);
        // A green launch's evidence (isolated data root, ~20 MB) is of no
        // further use; a red one's stays for the triage.
        if (status == 0 && evidence != null && evidence.existsSync()) {
          try {
            evidence.deleteSync(recursive: true);
          } on FileSystemException {
            // WebView2 can hold its profile a moment past the app's exit;
            // a leftover directory only costs disk.
          }
        }
      }
      if (exitCode == 0) exitCode = status;
      reports.add(
        distItestReport(
          path: file,
          exitCode: status,
          ms: sw.elapsedMilliseconds,
          tail: tail,
        ),
      );
    }
    return DistBatchRun(
      exitCode: exitCode,
      lines: expandDistItestReports(reports),
    );
  }

  /// Writes [kDistItestEntryPath] when its content changed (an unchanged
  /// file keeps the build incremental); returns its path.
  Future<String> _writeItestEntry() async {
    final ProcessResult r = await Process.run(distBashExecutable(), <String>[
      'tool/dist_test/itest_entry.sh',
    ], workingDirectory: _fushiDir);
    if (r.exitCode != 0) {
      throw DistWorkerError('itest_entry.sh failed: ${r.stderr}');
    }
    final File entry = File('$_fushiDir/$kDistItestEntryPath');
    final String text = '${r.stdout}';
    if (!entry.existsSync() || entry.readAsStringSync() != text) {
      entry
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);
    }
    return kDistItestEntryPath;
  }

  Future<Process> _startItest(String file) {
    if (Platform.isWindows) {
      return Process.start('powershell', <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        '$_fushiDir/tool/run_windows_itest.ps1',
        '-Target',
        kDistItestEntryPath,
        '-ApplicationBinary',
        // Absolute: flutter looks a relative binary up on PATH on Windows.
        File(
          '$_fushiDir/build/windows/x64/runner/Debug/fushi.exe',
        ).absolute.path,
        '-DistItest',
        file,
      ], workingDirectory: _fushiDir);
    }
    final Directory root = Directory.systemTemp.createTempSync('dist_itest_');
    return Process.start(
      FlutterSdkExecutables.current().flutter(),
      <String>[
        'drive',
        '--no-pub',
        '-d',
        'macos',
        '--driver=test_driver/integration_test.dart',
        '-t',
        kDistItestEntryPath,
        '--use-application-binary=build/macos/Build/Products/Debug/fushi.app',
      ],
      workingDirectory: _fushiDir,
      environment: <String, String>{
        ...distTestEnvironment(Platform.environment),
        'FUSHI_TEST_HIDDEN': '1',
        'FUSHI_TEST_ROOT': root.path,
        'FUSHI_TEST_RUN_ID': 'dist-itest-$pid',
        'FUSHI_DIST_ITEST': file,
      },
      includeParentEnvironment: false,
    );
  }

  /// The evidence directory run_windows_itest.ps1 printed, if any.
  Directory? _itestEvidence(List<String> output) {
    const String marker = '[itest] evidence: ';
    for (final String line in output.reversed) {
      final int at = line.indexOf(marker);
      if (at >= 0) return Directory(line.substring(at + marker.length).trim());
    }
    return null;
  }

  /// The end of a launch's output: on Windows the runner keeps flutter's
  /// output in [evidence]/command.log.
  String _itestTail(List<String> output, Directory? evidence) {
    final File? log = evidence == null
        ? null
        : File('${evidence.path}/command.log');
    final List<String> all = log != null && log.existsSync()
        ? log.readAsLinesSync()
        : output;
    // The app's progress lines (tests run / skipped) plus the end of output.
    return <String>[
      ...all.where(kDriveProgressLine.hasMatch),
      '...',
      ...all.skip(all.length > 40 ? all.length - 40 : 0),
    ].join('\n');
  }

  /// Runs [process] to the end with its output (stdout and stderr) in
  /// [stderrLog] under [header]; the stdout lines come back for the tail.
  Future<DistBatchRun> _runLogged(
    Process process, {
    required IOSink stderrLog,
    required Duration timeout,
    required String header,
  }) async {
    stderrLog.writeln(header);
    _process = process;
    await process.stdin.close();
    try {
      final DistBatchRun run = await _drive(
        process,
        stderrLog: stderrLog,
        timeout: timeout,
        kill: () async => _killTree(process),
        connectionFailure: null,
      );
      stderrLog
        ..writeAll(run.lines, '\n')
        ..writeln();
      return run;
    } finally {
      _process = null;
    }
  }

  void _killTree(Process p) {
    // By exact PID, never by process name: dart.exe is also the IDE's
    // analysis server.
    if (Platform.isWindows) {
      Process.runSync('taskkill', <String>['/PID', '${p.pid}', '/T', '/F']);
    } else {
      p.kill(ProcessSignal.sigkill);
    }
  }

  @override
  Future<DistBatchRun> analyze(
    List<String> paths, {
    required List<String> options,
    required IOSink stderrLog,
    required Duration timeout,
  }) => throw DistWorkerError(
    'analyze is only handed to other machines; run it here directly',
  );

  @override
  Future<DistBatchRun> build(
    DistBuild build, {
    required IOSink stderrLog,
    required Duration timeout,
  }) => throw DistWorkerError(
    'compile checks are only handed to other machines; build here directly',
  );

  @override
  Future<String?> jobBlocker(DistJob job) async => 'this machine';

  @override
  Future<void> cancel() async {
    final Process? p = _process;
    if (p != null) _killTree(p);
  }

  @override
  Future<void> finish(String runId) async {
    _lease?.release();
    _lease = null;
  }

  @override
  Future<String> status() async {
    final List<HeavyHolder> holders = readHeavyHolders(
      heavyStateDir(),
      heavySlotCount(readMemorySnapshot()),
    );
    return 'local, ${Platform.numberOfProcessors} cores, '
        '${holders.length} heavy slot(s) busy';
  }
}

class SshDistWorker extends DistWorker {
  SshDistWorker(super.config, {required this.repoRoot, this.primary});

  final String repoRoot;

  /// Set on secondary slots: they prepare after the primary, so its native
  /// libraries can be copied instead of built twice in parallel.
  final SshDistWorker? primary;
  final Completer<void> _prepared = Completer<void>();

  /// This run holds the checkout's lock (set once `init` got it).
  bool _locked = false;
  Process? _process;

  bool get _shim => config.kind == DistWorkerKind.sshShim;

  List<String> get _sshBase => <String>[
    ...kDistSshOptions,
    if (config.identity != null) ...<String>[
      '-i',
      config.identity!,
      '-o',
      'IdentitiesOnly=yes',
    ],
    config.host!,
  ];

  /// Remote shell prefix that only sets PATH.
  String get _pathPrefix => config.path.isEmpty
      ? ''
      : 'export PATH="${config.path.join(':')}:\$PATH"; ';

  /// Remote shell prefix: PATH, then into the checkout.
  String get _prefix =>
      '${_pathPrefix}cd "\$HOME"/${shellQuote(config.workdir)} && ';

  /// `-n`: no stdin to forward, so ssh can finish as soon as the remote
  /// command does.
  Future<ProcessResult> _ssh(String remoteCommand) => Process.run(
    distSshExecutable(),
    <String>['-n', ..._sshBase, remoteCommand],
  );

  /// The prepare step's process (ssh / git push) while one runs.
  Process? _stepProcess;

  /// [abandon] was called: no further prepare step starts.
  bool _abandoned = false;

  /// Runs one prepare step as a process [abandon] can stop.
  Future<ProcessResult> _step(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    if (_abandoned) throw DistWorkerError('$name: no longer needed');
    final Process p = await Process.start(
      executable,
      args,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    _stepProcess = p;
    await p.stdin.close();
    const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
    final Future<String> out = p.stdout.transform(decoder).join();
    final Future<String> err = p.stderr.transform(decoder).join();
    final int code = await p.exitCode;
    _stepProcess = null;
    final ProcessResult r = ProcessResult(p.pid, code, await out, await err);
    if (_abandoned) throw DistWorkerError('$name: no longer needed');
    return r;
  }

  @override
  Future<void> abandon() async {
    _abandoned = true;
    final Process? p = _stepProcess;
    if (p == null) return;
    // The local end only (with git push's ssh child): a remote prepare runs
    // on to warm the caches, and the next run's worker_kill.sh waits for it.
    if (Platform.isWindows) {
      await Process.run('taskkill', <String>['/PID', '${p.pid}', '/T', '/F']);
    } else {
      p.kill();
    }
  }

  Future<void> _sshChecked(String step, String command, IOSink log) async {
    final ProcessResult r = await _step(distSshExecutable(), <String>[
      '-n',
      ..._sshBase,
      command,
    ]);
    log
      ..writeln('== $step (exit ${r.exitCode})')
      ..write(r.stdout)
      ..write(r.stderr);
    if (r.exitCode != 0) {
      final String tail = '${r.stderr}'.trim().split('\n').last;
      throw DistWorkerError(
        '$step failed on $name (exit ${r.exitCode}): '
        '$tail',
      );
    }
  }

  @override
  Future<void> prepare(DistSnapshot snapshot, String runId, IOSink log) async {
    await primary?._prepared.future;
    try {
      await _prepare(snapshot, runId, log);
    } finally {
      if (!_prepared.isCompleted) _prepared.complete();
    }
  }

  Future<void> _prepare(DistSnapshot snapshot, String runId, IOSink log) async {
    if (_shim) return _prepareShim(snapshot, runId, log);
    final String workdir = shellQuote(config.workdir);
    final String seed = config.seedRepo == null
        ? ''
        : ' && { [ -s .git/objects/info/alternates ] || '
              '[ ! -d "\$HOME"/${shellQuote(config.seedRepo!)}/.git/objects ] || '
              'echo "\$HOME"/${shellQuote(config.seedRepo!)}/.git/objects '
              '> .git/objects/info/alternates; }';
    // One run per checkout: `mkdir` is the atomic test-and-set. The lock's
    // mtime is the heartbeat (worker_run.sh touches it while a batch runs);
    // one silent for [kDistLockStaleMinutes] belongs to a coordinator that
    // died and is taken over. Leftover batch processes are only killed once
    // the lock is ours: before that they may be another live run's.
    await _sshChecked(
      'init',
      'mkdir -p "\$HOME"/$workdir && cd "\$HOME"/$workdir && '
          '{ [ -d .git ] || git init -q; }$seed && '
          'mkdir -p .git/fushi-dist && '
          '{ mkdir .git/fushi-dist/lock 2>/dev/null || '
          '{ [ -n "\$(find .git/fushi-dist/lock -maxdepth 0 '
          '-mmin +$kDistLockStaleMinutes)" ] && rm -rf .git/fushi-dist/lock && '
          'mkdir .git/fushi-dist/lock; } || '
          '{ echo "busy: in use by dist_test run '
          '\$(cat .git/fushi-dist/lock/owner 2>/dev/null)" >&2; exit 75; }; } && '
          'echo $runId > .git/fushi-dist/lock/owner && '
          '{ [ ! -f fushi/tool/dist_test/worker_kill.sh ] || '
          'bash fushi/tool/dist_test/worker_kill.sh; }',
      log,
    );
    _locked = true;

    await _push(snapshot, runId, config.workdir, log);

    final String env = <String>[
      for (final MapEntry<String, String> e in config.prepareEnv.entries)
        '${e.key}=${shellQuote(e.value)}',
      if (config.nativePeer != null)
        'DIST_NATIVE_PEER="\$HOME"/${shellQuote(config.nativePeer!)}',
    ].join(' ');
    await _sshChecked(
      'checkout',
      '${_prefix}git checkout -q --detach --force ${snapshot.commit} && '
          "git clean -qfd -e 'native/*/prebuilt/' -e 'native/*/target/'",
      log,
    );
    // Output goes to a file on the worker and is printed afterwards: pub /
    // cargo / flutter can leave a daemon behind that inherits stdout, and an
    // inherited ssh channel keeps the connection open forever (seen on the
    // Mac: prepare finished, ssh never returned).
    await _sshChecked(
      'prepare',
      '$_prefix${env.isEmpty ? '' : 'env $env '}'
          'bash fushi/tool/dist_test/worker_prepare.sh '
          '> .git/fushi-dist-prepare.log 2>&1 < /dev/null; rc=\$?; '
          'cat .git/fushi-dist-prepare.log; exit \$rc',
      log,
    );
  }

  /// Pushes the snapshot to `refs/dist/<runId>` of the checkout at
  /// [remotePath] (an ssh-shim worker maps `work` / `work-N` to its own
  /// checkouts).
  Future<void> _push(
    DistSnapshot snapshot,
    String runId,
    String remotePath,
    IOSink log,
  ) async {
    final String sshCommand = <String>[
      distGitSshProgram(),
      for (final String a in _sshBase.sublist(0, _sshBase.length - 1))
        shellQuote(a),
    ].join(' ');
    final ProcessResult push = await _step(
      'git',
      <String>[
        'push',
        '--quiet',
        '${config.host}:$remotePath',
        '${snapshot.commit}:refs/dist/$runId',
      ],
      workingDirectory: repoRoot,
      environment: <String, String>{'GIT_SSH_COMMAND': sshCommand},
    );
    log
      ..writeln('== push (exit ${push.exitCode})')
      ..write(push.stdout)
      ..write(push.stderr);
    if (push.exitCode != 0) {
      throw DistWorkerError(
        'git push to $name failed: '
        '${'${push.stderr}'.trim()}',
      );
    }
  }

  /// The same steps through the shim's verbs: lock, push, prepare (checkout +
  /// worker_prepare.sh with the owner's prepare.env).
  Future<void> _prepareShim(
    DistSnapshot snapshot,
    String runId,
    IOSink log,
  ) async {
    final int slot = config.slotIndex;
    await _sshChecked(
      'lock',
      shimRequest('lock', <String>['$slot', runId]),
      log,
    );
    _locked = true;
    await _push(snapshot, runId, shimCheckoutName(slot), log);
    await _sshChecked(
      'prepare',
      shimRequest('prepare', <String>['$slot', snapshot.commit]),
      log,
    );
  }

  @override
  Future<DistBatchRun> run(
    DistBatch batch, {
    required String package,
    required List<String> flutterArgs,
    required IOSink stderrLog,
    required Duration timeout,
  }) async {
    for (final String f in batch.files) {
      if (!isSafeDistTestPath(f)) {
        throw DistWorkerError('refusing to send unsafe test path "$f"');
      }
    }
    if (!isDistPackageDir(package)) {
      throw DistWorkerError('refusing to send package "$package"');
    }
    final bool itest = batch.files.any(isDistItestPath);
    if (itest && (_shim || !batch.files.every(isDistItestPath))) {
      throw DistWorkerError(
        'integration tests run alone and never through the shim',
      );
    }
    // worker_run.sh (from the pushed snapshot, behind any shim) takes the
    // package option off and runs that package's suites.
    final List<String> args = <String>[
      if (package != kDistAppPackage)
        '$kDistPackageOption=${package.split('/').last}',
      ...flutterArgs,
    ];
    final String remote;
    if (itest) {
      remote = '${_prefix}bash fushi/tool/dist_test/worker_run.sh itest';
    } else if (_shim) {
      remote = shimRequest('run', <String>[
        '${config.slotIndex}',
        '${config.concurrency ?? 0}',
        ...args,
      ]);
    } else {
      remote =
          '${_prefix}bash fushi/tool/dist_test/worker_run.sh '
          '${<String>['${config.concurrency ?? 0}', ...args.map(shellQuote)].join(' ')}';
    }
    final Process process = await Process.start(distSshExecutable(), <String>[
      ..._sshBase,
      remote,
    ]);
    _process = process;
    process.stdin.write('${batch.files.join('\n')}\n');
    await process.stdin.close();
    final StringBuffer errors = StringBuffer();
    final DistBatchRun run;
    try {
      run = await _drive(
        process,
        stderrLog: stderrLog,
        timeout: timeout,
        kill: _killRemote,
        connectionFailure: (int code) => code,
        stderrCopy: errors,
      );
    } finally {
      _process = null;
    }
    if (run.exitCode == kDistShimBusy && run.lines.isEmpty) {
      final String reason = errors.toString().trim().split('\n').last;
      return DistBatchRun(
        exitCode: run.exitCode,
        lines: const <String>[],
        busy: reason.isEmpty ? 'busy' : reason,
      );
    }
    if (itest) {
      return DistBatchRun(
        exitCode: run.exitCode,
        lines: expandDistItestReports(run.lines),
        infraError: run.infraError,
      );
    }
    final ({List<String> lines, List<String> lcov}) split = splitDistCoverage(
      run.lines,
    );
    return DistBatchRun(
      exitCode: run.exitCode,
      lines: split.lines,
      infraError: run.infraError,
      coverage: split.lcov,
    );
  }

  @override
  Future<DistBatchRun> analyze(
    List<String> paths, {
    required List<String> options,
    required IOSink stderrLog,
    required Duration timeout,
  }) async {
    for (final String p in paths) {
      if (!isSafeDistAnalyzePath(p)) {
        throw DistWorkerError('refusing to send unsafe analyze path "$p"');
      }
    }
    return _job(
      _shim
          ? shimRequest('analyze', <String>['${config.slotIndex}', ...options])
          : '${_prefix}bash fushi/tool/dist_test/worker_analyze.sh '
                '${options.map(shellQuote).join(' ')}',
      input: paths.isEmpty ? '' : '${paths.join('\n')}\n',
      stderrLog: stderrLog,
      timeout: timeout,
    );
  }

  @override
  Future<DistBatchRun> build(
    DistBuild build, {
    required IOSink stderrLog,
    required Duration timeout,
  }) {
    // Builds download (Gradle, CMake), so they get the prepare step's
    // environment (the owner's prepare.env behind a shim).
    final String env = <String>[
      for (final MapEntry<String, String> e in config.prepareEnv.entries)
        '${e.key}=${shellQuote(e.value)}',
    ].join(' ');
    return _job(
      _shim
          ? shimRequest('build', <String>[
              '${config.slotIndex}',
              ...build.request,
            ])
          : '$_prefix${env.isEmpty ? '' : 'env $env '}'
                'bash fushi/tool/dist_test/worker_build.sh '
                '${build.request.map(shellQuote).join(' ')}',
      input: '',
      stderrLog: stderrLog,
      timeout: timeout,
    );
  }

  /// One [analyze] / [build] request: [input] on its stdin, its stdout
  /// collected. Turned down (busy), refused by an older shim, or a missing
  /// toolchain come back as not run, not as a red result.
  Future<DistBatchRun> _job(
    String remote, {
    required String input,
    required IOSink stderrLog,
    required Duration timeout,
  }) async {
    final Process process = await Process.start(distSshExecutable(), <String>[
      ..._sshBase,
      remote,
    ]);
    _process = process;
    process.stdin.write(input);
    await process.stdin.close();
    final StringBuffer errors = StringBuffer();
    final DistBatchRun run;
    try {
      run = await _drive(
        process,
        stderrLog: stderrLog,
        timeout: timeout,
        kill: _killRemote,
        connectionFailure: (int code) => code,
        stderrCopy: errors,
      );
    } finally {
      _process = null;
    }
    final String reason = errors.toString().trim().split('\n').last;
    if (run.exitCode == kDistShimBusy && run.lines.isEmpty) {
      return DistBatchRun(
        exitCode: run.exitCode,
        lines: const <String>[],
        busy: reason.isEmpty ? 'busy' : reason,
      );
    }
    // A shim installed before the verb existed refuses it: this machine
    // cannot take the work, which is not a red result.
    if (_shim && run.exitCode == kDistShimRefused && run.lines.isEmpty) {
      return DistBatchRun(
        exitCode: run.exitCode,
        lines: const <String>[],
        infraError: 'refused by the worker shim: $reason',
      );
    }
    if (run.exitCode == kDistToolchainMissing && run.lines.isEmpty) {
      return DistBatchRun(
        exitCode: run.exitCode,
        lines: const <String>[],
        infraError: reason.isEmpty ? 'toolchain missing' : reason,
      );
    }
    return run;
  }

  @override
  Future<String?> jobBlocker(DistJob job) async {
    // A trusted machine runs the checkout's own analyze script; only a
    // build depends on what is installed there.
    if (!_shim && job.build == null) return null;
    final ProcessResult r = await _hello();
    if (r.exitCode != 0) {
      return 'unreachable (exit ${r.exitCode})';
    }
    return distJobBlocker(parseDistHello('${r.stdout}'), job, shim: _shim);
  }

  /// The shim's `hello`. A trusted machine has no shim installed: the same
  /// script goes over on stdin, so both kinds report their toolchains alike.
  Future<ProcessResult> _hello() async {
    if (_shim) return _ssh('hello');
    final Process p = await Process.start(distSshExecutable(), <String>[
      ..._sshBase,
      '${_pathPrefix}SSH_ORIGINAL_COMMAND=hello bash -s',
    ]);
    p.stdin.write(
      File(
        '$repoRoot/fushi/tool/dist_test/worker_shim.sh',
      ).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    await p.stdin.close();
    const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
    final Future<String> out = p.stdout.transform(decoder).join();
    final Future<String> err = p.stderr.transform(decoder).join();
    final int code = await p.exitCode;
    return ProcessResult(p.pid, code, await out, await err);
  }

  Future<void> _killRemote() async {
    _process?.kill();
    await _ssh(
      _shim
          ? shimRequest('kill', <String>['${config.slotIndex}'])
          : '${_prefix}bash fushi/tool/dist_test/worker_kill.sh',
    );
  }

  @override
  Future<void> cancel() async {
    if (_process != null) await _killRemote();
  }

  @override
  Future<void> finish(String runId) async {
    if (!_locked) return;
    _locked = false;
    if (_shim) {
      await _ssh(shimRequest('finish', <String>['${config.slotIndex}', runId]));
      return;
    }
    await _ssh(
      '${_prefix}git update-ref -d refs/dist/$runId; '
      '[ "\$(cat .git/fushi-dist/lock/owner 2>/dev/null)" = $runId ] && '
      'rm -rf .git/fushi-dist/lock',
    );
  }

  @override
  Future<String> status() async {
    if (_shim) {
      final ProcessResult r = await _ssh('hello');
      if (r.exitCode != 0) {
        return 'unreachable (exit ${r.exitCode}): '
            '${'${r.stderr}'.trim().split('\n').last}';
      }
      return const LineSplitter()
          .convert('${r.stdout}'.trim())
          .map((String l) => l.trim())
          .join(', ');
    }
    final ProcessResult r = await _ssh(
      '$_pathPrefix'
      r'printf "%s, " "$(flutter --version 2>/dev/null | head -1)"; '
      r'printf "%s cores, " "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"; '
      r'printf "%s" "$(uptime | sed "s/.*load/load/")"',
    );
    if (r.exitCode != 0) {
      return 'unreachable (exit ${r.exitCode}): '
          '${'${r.stderr}'.trim().split('\n').last}';
    }
    return '${r.stdout}'.trim();
  }
}

/// Name of slot [slot]'s checkout on an ssh-shim worker, as `git push`
/// addresses it (the shim maps it under its own home).
String shimCheckoutName(int slot) => slot == 1 ? 'work' : 'work-$slot';

/// Words the shim accepts in a request: no quoting, no shell syntax, so the
/// request reaches it unchanged through sshd / cmd.exe / bash
/// (worker_shim.sh checks the same patterns).
final RegExp _shimWord = RegExp(r'^[A-Za-z0-9_,.:=+-]+$');

/// flutter test options the shim passes on: `--name`, `--name=value`, or a
/// plain value after one.
final RegExp _shimFlutterArg = RegExp(
  r'^(--[a-z][a-z-]*(=[A-Za-z0-9_,.:+-]*)?|[A-Za-z0-9_,.:+][A-Za-z0-9_,.:+-]*)$',
);

/// One request line for `worker_shim.sh`. Throws [DistWorkerError] for an
/// argument the shim would refuse, so the run stops here with the reason
/// instead of on the worker.
String shimRequest(String verb, List<String> args) {
  for (final String a in args) {
    if (!_shimWord.hasMatch(a) ||
        (verb == 'run' && !_shimFlutterArg.hasMatch(a))) {
      throw DistWorkerError(
        'ssh-shim workers only take plain flutter test options; '
        'cannot send "$a"',
      );
    }
  }
  return <String>[verb, ...args].join(' ');
}
